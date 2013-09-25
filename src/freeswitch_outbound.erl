% -module(freeswitch_outbound).

% %% API
% -export([start/3]).

% start(FSNode, Agent, Dest) ->
% 	CallerId = "OpenACD",
% 		freeswitch:api(FSNode, expand,
% 		" originate {origination_caller_id_number=" ++ CallerId ++
% 		"}sofia/${domain}/" ++ Agent ++
% 		"@${domain} &bridge({origination_caller_id_number=" ++ Agent ++
% 		"}sofia/${domain}/" ++
% 		Dest ++ "@${domain})").

-module(freeswitch_outbound).

-behaviour(gen_fsm).

-include_lib("openacd/include/agent.hrl").

%% API
-export([start_link/2,
         agent_pickup/1,
         call_destination/2,
         outbound_pickup/1]).

%% gen_fsm callbacks
-export([init/1, state_name/2, state_name/3,
         agent_ringing/2, outbound_ringing/2, oncall/2,
         awaiting_destination/3, oncall/3,
         handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-define(SERVER, ?MODULE).

-define(EVENT_KEY, outbound_call).
-define(ERR_NO_RESPONSE, "NO_USER_RESPONSE").
-define(ERR_NO_PICKUP, "UNALLOCATED_NUMBER").

-import(cpx_json_util, [l2b/1, b2l/1, nob/1]).

-record(state, {
        uuid,
        bleg,
        fnode,
        conn,
        agent,
        agent_pid,
        destination,
        client,
        type
    }).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> ok,Pid} | ignore | {error,Error}
%% Description:Creates a gen_fsm process which calls Module:init/1 to
%% initialize. To ensure a synchronized start-up procedure, this function
%% does not return until Module:init/1 has returned.
%%--------------------------------------------------------------------
start_link(Cnode, Props) ->
  gen_fsm:start_link(?MODULE, [Cnode, Props], []).

agent_pickup(Pid) ->
    lager:debug("In agent_pickup API", []),
    gen_fsm:send_event(Pid, agent_pickup).

call_destination(Pid, Client) ->
    lager:debug("In call_destination API with values ~p ~p", [Pid, Client]),
    gen_fsm:sync_send_event(Pid, {call_destination, Client}, infinity).

outbound_pickup(Pid) ->
    lager:debug("In outbound_pickup API" , []),
    gen_fsm:send_event(Pid, outbound_pickup).

%%====================================================================
%% gen_fsm callbacks
%%====================================================================
%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, StateName, State} |
%%                         {ok, StateName, State, Timeout} |
%%                         ignore                              |
%%                         {stop, StopReason}
%% Description:Whenever a gen_fsm is started using gen_fsm:start/[3,4] or
%% gen_fsm:start_link/3,4, this function is called by the new process to
%% initialize.
%%--------------------------------------------------------------------
init([Fnode, Props]) ->
    Type = proplists:get_value(type, Props),
    Agent = proplists:get_value(agent, Props),
    Conn = proplists:get_value(conn, Props),
    case Type of
        voicemail ->
            Dest = proplists:get_value(destination, Props),
            UUID = proplists:get_value(uuid, Props),
            CallerId = "OutboundCall",
            case freeswitch:api(Fnode, create_uuid) of
                {ok, BLeg} ->
                    originate(Fnode, BLeg, Dest, CallerId),
                    Time = util:now_ms(),
                    ouc_update(Conn, ?EVENT_KEY, UUID,
                        [{state, outgoing_ringing}, {timestamp, Time}]),
                    lager:debug("In call_destination state with bleg ~p", [BLeg]),
                    {ok, awaiting_destination,
                        #state{
                            uuid = UUID, fnode = Fnode,
                            agent = Agent, type = Type,
                            destination = Dest, bleg = BLeg,
                            conn = Conn}};
                _ -> {stop, uuid_not_created}
            end;
        _ ->
            Client = proplists:get_value(client, Props),
            Conn = proplists:get_value(conn, Props),
            AgentPid = proplists:get_value(agent_pid, Props),
            CallerId = "OpenACD",
            case freeswitch:api(Fnode, create_uuid) of
                {ok, UUID} ->
                    originate(Fnode, UUID, Agent, CallerId),
                    Time = util:now_ms(),
                    ouc_update(Conn, ?EVENT_KEY, UUID,
                        [{state, initiated}, {timestamp, Time}]),
                    {ok, precall, #state{uuid=UUID,
                            fnode=Fnode,
                            agent=Agent,
                            agent_pid=AgentPid,
                            client=Client,
                            conn=Conn}};
                _ -> {stop, uuid_not_created}
            end
    end.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, State) -> {next_state, NextStateName, NextState}|
%%                             {next_state, NextStateName,
%%                                NextState, Timeout} |
%%                             {stop, Reason, NewState}
%% Description:There should be one instance of this function for each possible
%% state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_event/2, the instance of this function with the same name as
%% the current state name StateName is called to handle the event. It is also
%% called if a timeout occurs.
%%--------------------------------------------------------------------
agent_ringing(agent_pickup, #state{
        fnode=Fnode, uuid=UUID, conn=Conn} = State) ->
    Time = util:now_ms(),
    ouc_update(Conn, ?EVENT_KEY, UUID,
        [{state, awaiting_destination}, {timestamp, Time}]),
    freeswitch:bgapi(Fnode, uuid_broadcast, UUID ++ " local_stream://moh"),
    {next_state, awaiting_destination, State};

agent_ringing(Event, State) ->
    lager:info("unhandled event ~p while in state ~p", [Event, agent_ringing]),
    {next_state, agent_ringing, State}.

outbound_ringing(outbound_pickup, #state{
        fnode=Fnode, uuid=UUID, bleg=BLeg, conn=Conn} = State) ->
    lager:debug("In outbound_pickup state", []),
    BridgeOutcome = freeswitch:api(Fnode, uuid_bridge,
    " " ++ BLeg ++
    " " ++ UUID),
    lager:debug("Bridge result : ~p", [BridgeOutcome]),
    Time = util:now_ms(),
    ouc_update(Conn, ?EVENT_KEY, UUID,
        [{state, oncall}, {timestamp, Time}]),
    {next_state, oncall, State};

outbound_ringing(Event, State) ->
    lager:info("unhandled event ~p while in state ~p", [Event, outbound_ringing]),
    {next_state, outbound_ringing, State}.

oncall(Event, State) ->
    lager:info("unhandled event ~p while in state ~p", [Event, oncall]),
    {next_state, oncall, State}.

state_name(_Event, State) ->
  {next_state, state_name, State}.

%%--------------------------------------------------------------------
%% Function:
%% state_name(Event, From, State) -> {next_state, NextStateName, NextState} |
%%                                   {next_state, NextStateName,
%%                                     NextState, Timeout} |
%%                                   {reply, Reply, NextStateName, NextState}|
%%                                   {reply, Reply, NextStateName,
%%                                    NextState, Timeout} |
%%                                   {stop, Reason, NewState}|
%%                                   {stop, Reason, Reply, NewState}
%% Description: There should be one instance of this function for each
%% possible state name. Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_event/2,3, the instance of this function with the same
%% name as the current state name StateName is called to handle the event.
%%--------------------------------------------------------------------

awaiting_destination({call_destination, Dest}, _From,
    #state{fnode=Fnode, uuid=UUID, conn=Conn} = State) ->
    CallerId = "OutboundCall",
    case freeswitch:api(Fnode, create_uuid) of
        {ok, BLeg} ->
            originate(Fnode, BLeg, Dest, CallerId),
            Time = util:now_ms(),
            ouc_update(Conn, ?EVENT_KEY, UUID,
                [{state, outgoing_ringing}, {timestamp, Time}]),
            lager:debug("In call_destination state with bleg ~p", [BLeg]),
            {reply, ok, awaiting_destination,
                State#state{destination = Dest, bleg = BLeg}};
        _ ->
            {stop, uuid_not_created}
    end;

awaiting_destination(Event, _From, State) ->
    lager:info("unhandled event ~p while in state ~p", [Event, awaiting_destination]),
    {reply, ok, awaiting_destination, State}.

oncall(Event, _From, State) ->
    lager:info("unhandled event ~p while in state ~p", [Event, oncall]),
    {reply, {error, existing_call}, oncall, State}.

state_name(_Event, _From, State) ->
  Reply = ok,
  {reply, Reply, state_name, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_event(Event, StateName, State) -> {next_state, NextStateName,
%%                                                NextState} |
%%                                          {next_state, NextStateName,
%%                                                NextState, Timeout} |
%%                                          {stop, Reason, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:send_all_state_event/2, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_event(Event, StateName, State) ->
	lager:debug("Received Event ~p", [Event]),
  {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_sync_event(Event, From, StateName,
%%                   State) -> {next_state, NextStateName, NextState} |
%%                             {next_state, NextStateName, NextState,
%%                              Timeout} |
%%                             {reply, Reply, NextStateName, NextState}|
%%                             {reply, Reply, NextStateName, NextState,
%%                              Timeout} |
%%                             {stop, Reason, NewState} |
%%                             {stop, Reason, Reply, NewState}
%% Description: Whenever a gen_fsm receives an event sent using
%% gen_fsm:sync_send_all_state_event/2,3, this function is called to handle
%% the event.
%%--------------------------------------------------------------------
handle_sync_event(Event, _From, StateName, State) ->
  Reply = ok,
  lager:debug("Received Event ~p", [Event]),
  {reply, Reply, StateName, State}.

%%--------------------------------------------------------------------
%% Function:
%% handle_info(Info,StateName,State)-> {next_state, NextStateName, NextState}|
%%                                     {next_state, NextStateName, NextState,
%%                                       Timeout} |
%%                                     {stop, Reason, NewState}
%% Description: This function is called by a gen_fsm when it receives any
%% other message than a synchronous or asynchronous event
%% (or a system message).
%%--------------------------------------------------------------------
% handle_info({call, {event, [UUID | Rest]}}, _StateName, Call, _Internal, State) when is_list(UUID) ->
%   SetSess = freeswitch:session_setevent(State#state.cnode, [
%     'CHANNEL_BRIDGE', 'CHANNEL_PARK', 'CHANNEL_HANGUP',
%     'CHANNEL_HANGUP_COMPLETE', 'CHANNEL_DESTROY', 'DTMF',
%     'CHANNEL_ANSWER', 'CUSTOM', 'conference::maintenance']),
%   lager:debug("reporting new call ~p (eventage:  ~p).", [UUID, SetSess]),
%   case State#state.uuid of
%     UUID -> freeswitch_media_manager:notify(UUID, self());
%     _ -> ok
%   end,
%   case_event_name([UUID | Rest], Call, State#state{in_control = true});

handle_info({call_event, {event, [UUID | EventPropList]}}, StateName, State) ->
    lager:debug("In call event info", []),
    case_event_name([UUID|EventPropList], StateName, State);

handle_info({call, {event, [UUID | _EventPropList]}}, agent_ringing,
        #state{uuid=UUID} = State) ->
    agent_pickup(self()),
    lager:debug("Call established in ~p", [self()]),
    {next_state, agent_ringing, State};

handle_info({call, {event, [BLeg | _EventPropList]}}, outbound_ringing,
        #state{bleg=BLeg} = State) ->
    lager:debug("BLeg established", []),
    outbound_pickup(self()),
    {next_state, outbound_ringing, State};

handle_info({error, Error}, _StateName, State) ->
    lager:debug("Error received: ~p", [Error]),
    {stop, Error, State};

handle_info({bgerror, _MsgID, Error}, _StateName, State) ->
    lager:debug("Error received: ~p", [Error]),
    ErrorTok = string:tokens(Error, " \n"),
    ErrorReply = case ErrorTok of
        ["-ERR"|[?ERR_NO_RESPONSE]] ->
            no_response;
        ["-ERR"|[?ERR_NO_PICKUP]] ->
            no_pickup;
        ["-ERR"|[ErrorList]] when is_list(ErrorList) ->
            cpx_json_util:l2b(ErrorList);
        Error1 ->
            lager:info("Unhandled error ~p", [Error1]),
            unknown_error
    end,
    {stop, ErrorReply, State};

handle_info(call_hangup, _StateName, State) ->
  lager:debug("Received call_hangup", []),
  {stop, normal, State};

% handle_info({bgok, UUID, Msg}, _StateName, State) ->
%     lager:info("UUID: ~p", [UUID]),
%     {next_state, outbound_ringing, State};

handle_info({bgok, _MsgID, Reply}, StateName,
    #state{fnode=Fnode, uuid=UUID, bleg=BLeg} = State) ->
    ReplyList = string:tokens(Reply, " \n"),
    NextState = case ReplyList of
        ["+OK"|[UUID]] ->
            handle_call(Fnode, UUID),
            agent_ringing;
        ["+OK"|[BLeg]] ->
            handle_call(Fnode, BLeg),
            outbound_ringing;
        Reply1 ->
            lager:debug("Reply : ~p", [Reply1]),
            StateName
    end,
    {next_state, NextState, State};

handle_info(Info, StateName, State) ->
  lager:debug("Received Info ~p\nStateName ~p\nState ~p", [Info,StateName,State]),
  {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(Reason, _StateName, #state{
        uuid=UUID, conn=Conn, agent=Agent, agent_pid=AgentPid} = _State) ->
    Time = util:now_ms(),
    ouc_update(Conn, ?EVENT_KEY, UUID,
        [{state, ended}, {reason, Reason}, {timestamp, Time}]),
    ARec = agent:dump_state(AgentPid),
    AvailChan = ARec#agent.available_channels,
    NewAvail = AvailChan ++ [voice],
    agent_manager:set_avail(Agent, NewAvail),
    ok.

%%--------------------------------------------------------------------
%% Function:
%% code_change(OldVsn, StateName, State, Extra) -> {ok, StateName, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, StateName, State, _Extra) ->
  {ok, StateName, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
originate(Fnode, UUID, Agent, CallerId) ->
    freeswitch:bgapi(Fnode, expand,
            "originate {origination_uuid=" ++ UUID ++
            ",ignore_early_media=true" ++
            ",origination_caller_id_number=" ++ Agent ++
            ",origination_caller_id_name=" ++ CallerId ++
            ",hangup_after_bridge=true}sofia/${domain}/" ++ Agent ++
            "@${domain} &park()").

case_event_name([UUID| EventPropList], StateName, State) ->
    lager:debug("In case event", []),
    Ename = case proplists:get_value("Event-Name", EventPropList) of
        "CUSTOM" -> {"CUSTOM", proplists:get_value("Event-Subclass", EventPropList)};
        Else -> Else
    end,
    lager:debug("Event ~p for ~p ", [Ename, UUID]),
    case_event_name(Ename, UUID, StateName, State).

case_event_name("CHANNEL_PARK", _UUID, StateName, State) ->
    {next_state, StateName, State};

case_event_name(_Other, _UUID, StateName, State) ->
    lager:debug("In case event/4", []),
    {next_state, StateName, State}.

ouc_update(Conn, Event, CallId, Data) ->
  Conn ! {Event, {l2b(CallId), Data}}.

handle_call(Fnode, UUID) ->
    Reply = freeswitch:handlecall(Fnode, UUID),
    lager:debug("handlecall reply for UUID ~p: ~p", [UUID, Reply]).