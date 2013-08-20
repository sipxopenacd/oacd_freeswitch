%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

-module(freeswitch_voicemail).

-behaviour(gen_media).
-behaviour(gen_media_playable).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-include_lib("openacd/include/queue.hrl").
-include_lib("openacd/include/call.hrl").
-include_lib("openacd/include/agent.hrl").
%-include_lib("openacd/include/gen_media.hrl").
-include("cpx_freeswitch_pb.hrl").

-define(TIMEOUT, 10000).

%% API
-export([
	start/7,
	start_link/7,
	get_call/1,
	dump_state/1]).

%% gen_media callbacks
-export([
	init/1,
	prepare_endpoint/2,
	handle_ring/4,
	handle_ring_stop/4,
	handle_answer/5,
	handle_agent_transfer/4,
	handle_queue_transfer/5,
	handle_wrapup/5,
	handle_call/6,
	handle_cast/5,
	handle_info/5,
	handle_hold/2,
	handle_unhold/2,
	handle_warm_transfer_begin/3,
	terminate/5,
	code_change/4]).

%% gen_media_playable callbacks
-export([
	handle_play/3,
	handle_play/4,
	handle_pause/3]).

-record(state, {
	cook :: pid() | 'undefined',
	queue :: string() | 'undefined',
	queue_pid :: pid() | 'undefined',
	cnode :: atom(),
	agent :: string() | 'undefined',
	agent_pid :: pid() | 'undefined',
	ringchannel :: pid() | 'undefined',
	ringuuid :: string() | 'undefined',
	xferchannel :: pid() | 'undefined',
	xferuuid :: string() | 'undefined',
	manager_pid :: 'undefined' | any(),
	file = erlang:error({undefined, file}):: string(),
	answered = false :: boolean(),
	caseid :: string() | 'undefined',
	time = util:now() :: integer(),
	playback = stop :: stop | play | pause,
	playback_ms :: non_neg_integer() | 'undefined',
	playback_sample_count :: non_neg_integer() | 'undefined'
}).

-type(state() :: #state{}).
-define(GEN_MEDIA, true).
-include_lib("openacd/include/gen_spec.hrl").

%%====================================================================
%% API
%%====================================================================
%% @doc starts the freeswitch media gen_server.  `Cnode' is the C node the communicates directly with freeswitch.
-spec(start/7 :: (Cnode :: atom(), UUID :: string(), File :: string(), Queue :: string(), Priority :: pos_integer(), Client :: #client{} | string(), Info :: list()) -> {'ok', pid()}).
start(Cnode, UUID, File, Queue, Priority, Client, Info) ->
	gen_media:start(?MODULE, [Cnode, UUID, File, Queue, Priority, Client, Info]).

-spec(start_link/7 :: (Cnode :: atom(), UUID :: string(), File :: string(), Queue :: string(), Priority :: pos_integer(), Client :: #client{} | string(), Info :: list()) -> {'ok', pid()}).
start_link(Cnode, UUID, File, Queue, Priority, Client, Info) ->
	gen_media:start_link(?MODULE, [Cnode, UUID, File, Queue, Priority, Client, Info]).

%% @doc returns the record of the call freeswitch media `MPid' is in charge of.
-spec(get_call/1 :: (MPid :: pid()) -> #call{}).
get_call(MPid) ->
	gen_media:get_call(MPid).

-spec(dump_state/1 :: (Mpid :: pid()) -> #state{}).
dump_state(Mpid) when is_pid(Mpid) ->
	gen_media:call(Mpid, dump_state).

%%====================================================================
%% gen_media callbacks
%%====================================================================
%% @private
init([Cnode, UUID, File, Queue, Priority, Client, Info]) ->
	process_flag(trap_exit, true),
	Manager = whereis(freeswitch_media_manager),
	PlaybackMs = list_to_integer(proplists:get_value(record_ms, Info)),
	PlaybackSampleCount = list_to_integer(proplists:get_value(record_samples, Info)),
	lager:info("Length of voicemail: ~p ms, ~p samples", [PlaybackMs, PlaybackSampleCount]),

	PsInfo = [{playback_ms, PlaybackMs}],

	Ps = [
		{id, UUID++"-vm"},
		{type, voice},
		{priority, Priority},
		{client, Client},
		{media_path, inband},
		{queue, Queue},
		{info, PsInfo}
	],

	%% @todo remove dependency to cpx_supervisor for archive path
	Callrec = #call{id=UUID++"-vm", type=voice, source=self(), priority = Priority, client = Client, media_path = inband},
	case cpx_supervisor:get_archive_path(Callrec) of
		none ->
			lager:debug("archiving is not configured", []);
		{error, _Reason, Path} ->
			lager:warning("Unable to create requested call archiving directory for recording ~p", [Path]);
		Path ->
			Ext = filename:extension(File),
			lager:debug("archiving to ~s~s", [Path, Ext]),
			file:copy(File, Path++Ext)
	end,
	{ok, #state{cnode=Cnode, manager_pid = Manager, file=File, playback_ms = PlaybackMs, playback_sample_count = PlaybackSampleCount}, Ps}.

prepare_endpoint(Agent,Options) ->
	freeswitch_media:prepare_endpoint(Agent, Options).

%% start playback
handle_answer(Apid, oncall_ringing, Call, _GenMediaState, #state{xferchannel=XferChan} = State) when is_pid(XferChan) ->
	Node = State#state.cnode,
	XferUUID = State#state.xferuuid,
	File = State#state.file,
	PlaybackMs = State#state.playback_ms,
	link(XferChan),
	%freeswitch_ring:hangup(State#state.ringchannel),
	% freeswitch:sendmsg(State#state.cnode, State#state.xferuuid,
	% 	[{"call-command", "execute"},
	% 		{"event-lock", "true"},
	% 		{"execute-app-name", "phrase"},
	% 		{"execute-app-arg", "voicemail_say_date,"++integer_to_list(State#state.time)}]),
	lager:info("Voicemail ~s successfully transferred! Time to play ~s", [Call#call.id, File]),
	start_playback(Node, XferUUID, File),
	start_event(Apid, Call, PlaybackMs, 0),
	{ok, State#state{agent_pid = Apid, ringchannel = XferChan,
			ringuuid = XferUUID, xferuuid = undefined, xferchannel = undefined, answered = true, playback = play}};

%% start playback
handle_answer(Apid, inqueue_ringing, Call, GenMediaState, State) ->
	Node = State#state.cnode,
	File = State#state.file,
	PlaybackMs = State#state.playback_ms,
	RingPid = case GenMediaState of
		#inqueue_ringing_state{outband_ring_pid = P} -> P;
		#oncall_ringing_state{outband_ring_pid = P} -> P
	end,
	RingUUID = case is_pid(RingPid) of
		true -> freeswitch_ring:get_uuid(RingPid);
		_ -> ""
	end,
	% freeswitch:sendmsg(State#state.cnode, RingUUID,
	% 	[{"call-command", "execute"},
	% 		{"event-lock", "true"},
	% 		{"execute-app-name", "phrase"},
	% 		{"execute-app-arg", "voicemail_say_date,"++integer_to_list(State#state.time)}]),
	lager:info("Voicemail ~s successfully answered! Time to play ~s", [Call#call.id, File]),
	start_playback(Node, RingUUID, File),
	start_event(Apid, Call, PlaybackMs, 0),
	{ok, State#state{agent_pid = Apid, answered = true, ringuuid = RingUUID, playback = play}}.

%% Currently not used
handle_ring(_Apid, _RingData, _Callrec, State) ->
	{ok, State}.

% handle_ring(Apid, RingData, Callrec, State) when is_pid(Apid) ->
% 	AgentRec = agent:dump_state(Apid),
% 	handle_ring({Apid, AgentRec}, RingData, Callrec, State);
% handle_ring({_Apid, #agent{ring_channel = {undefined, persistent, _}} = Agent}, _RingData, _Callrec, State) ->
% 	lager:warning("Agent (~p) does not have it's persistent channel up yet", [Agent#agent.login]),
% 	{invalid, State};

% handle_ring({Apid, #agent{ring_channel = {EndpointPid, persistent, _EndpointType}} = _Agent}, _RingData, _Callrec, State) ->
% 	lager:info("Ring channel made things happy, I assume", []),
% 	{ok, [{"caseid", State#state.caseid}], State#state{ringchannel = EndpointPid, ringuuid = freeswitch_ring:get_uuid(EndpointPid), agent_pid = Apid}};

% handle_ring({Apid, #agent{ring_channel = {EndpointPid, transient, _EndpintType}} = _Agent}, _RingData, _Callrec, State) when is_pid(EndpointPid) ->
% 	lager:info("Agent already has transient ring pid up:  ~p", [EndpointPid]),
% 	{ok, [{"caseid", State#state.caseid}], State#state{ringchannel = EndpointPid, ringuuid = freeswitch_ring:get_uuid(EndpointPid), agent_pid = Apid}}.

handle_ring_stop(_Statename, _Callrec, _GenMediaState, State) ->
	lager:debug("hanging up ring channel", []),
	case State#state.ringchannel of
		undefined ->
			ok;
		RingChannel ->
			freeswitch_ring:hangup(RingChannel)
	end,
	{ok, State#state{ringchannel=undefined}}.

handle_agent_transfer(AgentPid, Timeout, Call, State) ->
	lager:info("transfer_agent to ~p for call ~p", [AgentPid, Call#call.id]),
	AgentRec = agent:dump_state(AgentPid),
	% fun that returns another fun when passed the UUID of the new channel
	% (what fun!)
	F = fun(_UUID) ->
		fun(ok, _Reply) ->
			% agent picked up?
			ok;
		(error, Reply) ->
			lager:warning("originate failed: ~p", [Reply])
			%agent:set_state(AgentPid, idle)
		end
	end,

	F2 = fun(UUID, EventName, Event) ->
			case EventName of
				"DTMF" ->
					case proplists:get_value("DTMF-Digit", Event) of
						"5" ->
							freeswitch:sendmsg(State#state.cnode, UUID,
								[{"call-command", "execute"},
									{"execute-app-name", "playback"},
									{"execute-app-arg", State#state.file}]);
						_ ->
							ok
					end;
				"CHANNEL_EXECUTE_COMPLETE" ->
					File = State#state.file,
					case proplists:get_value("Application-Data", Event) of
						File ->
							lager:notice("Finished playing voicemail recording", []);
						_ ->
							ok
					end;
				_ ->
					ok
			end,
			true
	end,
	case freeswitch_ring:start(State#state.cnode, AgentRec, AgentPid, Call, Timeout, F, [single_leg, {eventfun, F2}, {needed_events, ['DTMF', 'CHANNEL_EXECUTE_COMPLETE']}]) of
		{ok, Pid} ->
			{ok, [{"caseid", State#state.caseid}], State#state{agent_pid = AgentPid, xferchannel = Pid, xferuuid = freeswitch_ring:get_uuid(Pid)}};
		{error, Error} ->
			lager:error("error:  ~p", [Error]),
			{error, Error, State}
	end.

-spec(handle_warm_transfer_begin/3 :: (Number :: string(), Call :: #call{}, State :: any()) -> {'invalid', #state{}}).
handle_warm_transfer_begin(_Number, _Call, State) ->
	{invalid, State}.

handle_wrapup(_From, _StateName, #call{media_path = inband} = _Call, _GenMediaState, State) ->
	lager:debug("Handling wrapup request", []),
	% TODO This could prolly stand to be a bit more elegant.
	freeswitch:api(State#state.cnode, uuid_kill, State#state.ringuuid),
	{hangup, State};
handle_wrapup(_From, _Statename, _Call, _GenMediaState, State) ->
	% TODO figure out what to do if anything.  If nothing, remove todo.
	{ok, State}.

handle_queue_transfer(_Queue, _Statename, _Call, _GenMediaState, #state{ringchannel = Channel} = State) when is_pid(Channel) ->
	freeswitch_ring:hangup(Channel),
	{ok, State#state{ringchannel = undefined, xferchannel=undefined, xferuuid=undefined, answered = false}};

handle_queue_transfer(_Queue, _Statename, _Call, _GenMediaState, State) ->
	{ok, State#state{answered = false}}.

%%--------------------------------------------------------------------
%% Description: Handling call messages
%%--------------------------------------------------------------------

%% @private
handle_call(get_call, _From, _, Call, _, State) ->
	{reply, Call, State};
handle_call(get_queue, _From, _, _Call, _, State) ->
	{reply, State#state.queue_pid, State};
handle_call(get_agent, _From, _, _Call, _, State) ->
	{reply, State#state.agent_pid, State};
handle_call({set_agent, Agent, Apid}, _From, _, _Call, _, State) ->
	{reply, ok, State#state{agent = Agent, agent_pid = Apid}};
handle_call(dump_state, _From, _, _Call, _, State) ->
	{reply, State, State};
handle_call(Msg, _From, _, _Call, _, State) ->
	lager:info("unhandled mesage ~p", [Msg]),
	{reply, ok, State}.

%%--------------------------------------------------------------------
%% Description: Handling cast messages
%%--------------------------------------------------------------------
%% @private
handle_cast({set_caseid, CaseID}, _, _Call, _, State) ->
	{noreply, State#state{caseid = CaseID}};

handle_cast(replay, _, _Call, _, #state{file = File} = State) ->
	start_playback(State#state.cnode, State#state.ringuuid, File),
	{noreply, State};

%% web api
handle_cast({<<"replay">>, _}, Statename, Call, Gmstate, State) ->
	handle_cast(replay, Statename, Call, Gmstate, State);

%% tcp api
handle_cast(Request, Statename, Call, Gmstate, State) when is_record(Request, mediacommandrequest) ->
	FixedRequest = cpx_freeswitch_pb:decode_extensions(Request),
	Hint = case cpx_freeswitch_pb:get_extension(FixedRequest, freeswitch_voicemail_request_hint) of
		{ok, O} -> O;
		_ -> undefined
	end,
	case Hint of
		'REPLAY' ->
			handle_cast(replay, Statename, Call, Gmstate, State);
		Else ->
			lager:info("Invalid request hint:  ~p", [Else]),
			{noreply, State}
	end;

handle_cast(_Msg, _, _Call, _, State) ->
	{noreply, State}.

%%--------------------------------------------------------------------
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
%% @private
handle_info(check_recovery, _Statename, Call, _GenMediaState, State) ->
	case whereis(freeswitch_media_manager) of
		Pid when is_pid(Pid) ->
			link(Pid),
			gen_server:cast(freeswitch_media_manager, {notify, Call#call.id, self()}),
			{noreply, State#state{manager_pid = Pid}};
		_Else ->
			{ok, Tref} = timer:send_after(1000, check_recovery),
			{noreply, State#state{manager_pid = Tref}}
	end;

handle_info({'EXIT', Pid, Reason}, oncall_ringing, _Call, _GenMediaState, #state{xferchannel = Pid} = State) ->
	lager:warning("Handling transfer channel ~w exit ~p", [Pid, Reason]),
	{stop_ring, State#state{ringchannel = undefined}};

handle_info({'EXIT', Pid, Reason}, oncall_ringing, _Call, _GenMediaState, #state{ringchannel = Pid, answered = true, xferchannel = undefined} = State) ->
	lager:warning("Handling ring channel ~w exit ~p after answered, no transfer", [Pid, Reason]),
	{stop, {hangup, "agent"}, State};

handle_info({'EXIT', Pid, Reason}, inqueue_ringing, _Call, _GenMediaState, #state{ringchannel = Pid} = State) ->
	lager:warning("Handling ring channel ~w exit ~p", [Pid, Reason]),
	% we die w/ the ring channel because we want the agent o be able to
	% go to wrapup simply by hanging up the phone (at least in the case of
	% a transient ring channel)
	{stop_ring, State#state{ringchannel = undefined}};

handle_info({'EXIT', Pid, Reason}, _Statename, _Call, _GenMediaState, #state{manager_pid = Pid} = State) ->
	lager:warning("Handling manager exit from ~w due to ~p", [Pid, Reason]),
	{ok, Tref} = timer:send_after(1000, check_recovery),
	{noreply, State#state{manager_pid = Tref}};

handle_info(call_hangup, _Statename, _Call, _GenMediaState, State) ->
	catch freeswitch_ring:hangup(State#state.ringchannel),
	% see the code that handles the exit of the ring channel pid for why we
	% stop.
	{stop, normal, State};

handle_info({event, playback_stop, Call}, _Statename, _, _GenMediaState, State) ->
	Apid = State#state.agent_pid,
	PlaybackMs = State#state.playback_ms,

	stop_event(Apid, Call, PlaybackMs),
	{noreply, State#state{playback = stop}};

handle_info(Info, _Statename, _Call, _GenMediaState, State) ->
	lager:info("unhandled info ~p", [Info]),
	{noreply, State}.

%%--------------------------------------------------------------------
%% handle_hold
%%--------------------------------------------------------------------

handle_hold(_GenmediaState, State) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% handle_unhold
%%--------------------------------------------------------------------

handle_unhold(_GenmediaState, State) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% handle_play
%%--------------------------------------------------------------------

%% resume
handle_play(Call, _GenmediaState, #state{playback=Playback} = State) when Playback =:= pause ->
	Apid = State#state.agent_pid,
	Node = State#state.cnode,
	UUID = State#state.ringuuid, 
	PlaybackMs = State#state.playback_ms,
	resume_playback(Node, UUID),
	resume_event(Apid, Call, PlaybackMs),
	{ok, State#state{playback = play}};

%% replay
handle_play(Call, _GenmediaState, State) when State#state.playback =:= stop ->
	Apid = State#state.agent_pid,
	Node = State#state.cnode,
	UUID = State#state.ringuuid,
	File = State#state.file,
	PlaybackMs = State#state.playback_ms,
	lager:info("Voicemail playback started"),
	start_playback(Node, UUID, File),
	start_event(Apid, Call, PlaybackMs, 0),
	{ok, State#state{playback = play}};

handle_play(_Call, _GenmediaState, State) ->
	lager:debug("Voicemail playback already started; ignoring request"),
	{ok, State}.

%% seek
handle_play(Opts, Call, _GenmediaState, State) when State#state.playback =:= play ->
	Location = ej:get({"location"}, Opts),
	Apid = State#state.agent_pid,
	PlaybackMs = State#state.playback_ms,
	lager:info("While playing, calling uuid_fileman " ++ State#state.ringuuid ++ " seek:" ++ integer_to_list(Location)),
	seek_playback(State#state.cnode, State#state.ringuuid, State#state.file, Location),
	start_event(Apid, Call, PlaybackMs, Location),
	{ok, State};

%% resume and seek
handle_play(Opts, Call, _GenmediaState, State) when State#state.playback =:= pause ->
	Location = ej:get({"location"}, Opts),
	lager:info("While paused, calling uuid_fileman " ++ State#state.ringuuid ++ " seek:" ++ integer_to_list(Location)),
	Apid = State#state.agent_pid,
	Node = State#state.cnode,
	UUID = State#state.ringuuid,
	% unpause
	PlaybackMs = State#state.playback_ms,
	% resume_playback(Node, UUID),
	seek_playback(Node, UUID, State#state.file, Location),
	start_event(Apid, Call, PlaybackMs, Location),
	% freeswitch:api(State#state.cnode, uuid_fileman, State#state.ringuuid ++ " seek:" ++ integer_to_list(Location)),
	{ok, State#state{playback = play}};

%% start and seek
handle_play(Opts, Call, _GenmediaState, State) when State#state.playback =:= stop ->
	Location = ej:get({"location"}, Opts),
	lager:info("While stop, calling uuid_fileman " ++ State#state.ringuuid ++ " seek:" ++ integer_to_list(Location)),
	PlaybackMs = State#state.playback_ms,
	Apid = State#state.agent_pid,

	start_playback(State#state.cnode, State#state.ringuuid, State#state.file, Location),
	start_event(Apid, Call, PlaybackMs, Location),
	{ok, State#state{playback = play}};

handle_play(_Opts, _Call, _GenmediaState, State) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% handle_pause
%%--------------------------------------------------------------------

handle_pause(Call, _GenmediaState, State) when State#state.playback =:= play ->
	Apid = State#state.agent_pid,
	PlaybackMs = State#state.playback_ms,
	pause_playback(State#state.cnode, State#state.ringuuid),
	pause_event(Apid, Call, PlaybackMs),
	% freeswitch:api(State#state.cnode, uuid_fileman, State#state.ringuuid ++ " pause"),
	{ok, State#state{playback = pause}};

handle_pause(_Call, _GenmediaState, State) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Function: terminatingrminate(Reason, State) -> void()
%%--------------------------------------------------------------------
%% @private
terminate(Reason, _Statename, _Call, _GenMediaState, _State) ->
	% TODO - delete the recording or archive it somehow
	lager:notice("terminating: ~p", [Reason]),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%%--------------------------------------------------------------------
%% @private
code_change(_OldVsn, _Call, State, _Extra) ->
	{ok, State}.


%% Internal functions

start_playback(Node, Uuid, File) ->
	freeswitch:sendmsg(Node, Uuid, [
		{"call-command", "execute"},
		{"event-lock", "true"},
		{"execute-app-name", "playback"},
		{"execute-app-arg", File}]).

start_playback(Node, Uuid, File, Location) ->
	LocationSample = Location * 16, % TODO derive from variable_read_rate
	LocationSuffix = "@@" ++ integer_to_list(LocationSample),
	freeswitch:sendmsg(Node, Uuid, [
		{"call-command", "execute"},
		{"event-lock", "true"},
		{"execute-app-name", "playback"},
		{"execute-app-arg", File ++ LocationSuffix}]).

pause_playback(Node, Uuid) ->
	freeswitch:api(Node, uuid_fileman, Uuid ++ " pause").

resume_playback(Node, Uuid) ->
	freeswitch:api(Node, uuid_fileman, Uuid ++ " pause").

seek_playback(Node, Uuid, File, Location) ->
	freeswitch:api(Node, break, Uuid ++ " all"),
	start_playback(Node, Uuid, File, Location).

start_event(Apid, Call, PlaybackMs, Location) ->
	Update = {channel_playback_update, [
		{<<"type">>, started},
		{<<"location">>, Location},
		{<<"source_module">>, ?MODULE},
		{<<"playback_ms">>, PlaybackMs}
	]},
	agent_channel:media_push(Apid, Call, Update).

resume_event(Apid, Call, PlaybackMs) ->
	Update = {channel_playback_update, [
		{<<"type">>, resumed},
		{<<"source_module">>, ?MODULE},
		{<<"playback_ms">>, PlaybackMs}
	]},
	agent_channel:media_push(Apid, Call, Update).

pause_event(Apid, Call, PlaybackMs) ->
	Update = {channel_playback_update, [
		{<<"type">>, paused},
		{<<"source_module">>, ?MODULE},
		{<<"playback_ms">>, PlaybackMs}
	]},
	agent_channel:media_push(Apid, Call, Update).

stop_event(Apid, Call, PlaybackMs) ->
	Update = {channel_playback_update, [
		{<<"type">>, stopped},
		{<<"source_module">>, ?MODULE},
		{<<"playback_ms">>, PlaybackMs}
	]},
	agent_channel:media_push(Apid, Call, Update).