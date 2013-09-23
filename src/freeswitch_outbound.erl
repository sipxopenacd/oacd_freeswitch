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

%% API
-export([start_link/4,
         agent_pickup/1,
         outbound_pickup/1]).

%% gen_fsm callbacks
-export([init/1, state_name/2, state_name/3,
         agent_ringing/2, outbound_ringing/2,
         handle_event/3,
         handle_sync_event/4, handle_info/3, terminate/3, code_change/4]).

-define(SERVER, ?MODULE).

-define(EVENT_KEY, outbound_call).

-import(cpx_json_util, [l2b/1, b2l/1, nob/1]).

-record(state, {
        uuid,
        bleg,
        fnode,
        conn,
        agent,
        destination
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
start_link(Cnode, Agent, Dest, Conn) ->
  gen_fsm:start_link(?MODULE, [Cnode, Agent, Dest, Conn], []).

agent_pickup(Pid) ->
    lager:info("In agent_pickup API", []),
    gen_fsm:send_event(Pid, agent_pickup).

outbound_pickup(Pid) ->
    lager:info("In outbound_pickup API" , []),
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
init([Fnode, Agent, Dest, Conn]) ->
    CallerId = "OpenACD",
    case freeswitch:api(Fnode, create_uuid) of
        {ok, UUID} ->
            freeswitch:api(Fnode, originate,
            " {origination_uuid=" ++ UUID ++
            ",origination_caller_id_number=" ++ Agent ++
            ",origination_caller_id_name=" ++ CallerId ++
            ",hangup_after_bridge=true}sofia/openucrpm.ezuce.ph/" ++ Agent ++
            "@openucrpm.ezuce.ph &park()"),
            lager:info("testing output", []),
            Reply = freeswitch:handlecall(Fnode, UUID),
            lager:info("handlecall reply for UUID ~p: ~p", [UUID, Reply]),
            ouc_update(Conn, ?EVENT_KEY, UUID, [{state, agent_ringing}]),
            {ok, agent_ringing, #state{uuid=UUID,
                    fnode=Fnode,
                    agent=Agent,
                    destination=Dest,
                    conn=Conn}};
            % freeswitch:api(Cnode, expand,
            % " originate {origination_uuid=" ++ UUID ++
            % ",origination_caller_id_number=" ++ CallerId ++
            % "}sofia/${domain}/" ++ Agent ++
            % "@${domain} &bridge({origination_uuid=" ++ BLeg ++
            % ",origination_caller_id_number=" ++ Agent ++
            % "}sofia/${domain}/" ++
            % Dest ++ "@${domain})"),
        _ -> {stop, uuid_not_created}
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
        agent=Agent, fnode=Fnode, uuid=UUID,
        destination=Dest, conn=Conn} = State) ->
    lager:info("In agent_pickup state", []),
    case freeswitch:api(Fnode, create_uuid) of
        {ok, BLeg} ->
            freeswitch:api(Fnode, expand,
            " originate {origination_uuid=" ++ BLeg ++
            ",origination_caller_id_number=" ++ Dest ++
            ",origination_caller_id_name='Outbound Call'" ++
            ",hangup_after_bridge=true}sofia/${domain}/" ++ Dest ++
            "@${domain} &park()"),
            case freeswitch:handlecall(Fnode, BLeg) of
                {error, Error} ->
                    ouc_update(Conn, ?EVENT_KEY, UUID, [{state, stopped}]),
                    {stop, Error, State};
                Reply -> lager:info("handlecall reply for UUID ~p: ~p", [BLeg, Reply]),
                    ouc_update(Conn, ?EVENT_KEY, UUID, [{state, outbound_ringing}]),
                    {next_state, outbound_ringing, State#state{bleg = BLeg}}
            end;
        _ ->
            ouc_update(Conn, ?EVENT_KEY, UUID, [{state, agent_pickup}]),
            {next_state, agent_pickup, State}
    end.

outbound_ringing(outbound_pickup, #state{
        fnode=Fnode, uuid=UUID, bleg=BLeg, conn=Conn} = State) ->
    lager:info("In outbound_pickup state", []),
    BridgeOutcome = freeswitch:api(Fnode, uuid_bridge,
    " " ++ BLeg ++
    " " ++ UUID),
    lager:info("Bridge result : ~p", [BridgeOutcome]),
    ouc_update(Conn, ?EVENT_KEY, UUID, [{state, oncall}]),
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
	lager:info("Received Event ~p", [Event]),
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
  lager:info("Received Event ~p", [Event]),
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
    lager:info("In call event info", []),
    case_event_name([UUID|EventPropList], StateName, State);

handle_info({call, {event, [UUID | _EventPropList]}}, agent_ringing,
        #state{uuid=UUID} = State) ->
    agent_pickup(self()),
    lager:info("Call established in ~p", [self()]),
    {next_state, agent_ringing, State};

handle_info({call, {event, [BLeg | _EventPropList]}}, outbound_ringing,
        #state{bleg=BLeg} = State) ->
    lager:info("BLeg established", []),
    outbound_pickup(self()),
    {next_state, outbound_ringing, State};

handle_info({error, Error}, _StateName, State) ->
    lager:info("Error received: ~p", [Error]),
    {stop, Error, State};

handle_info(call_hangup, _StateName, State) ->
  lager:info("Received call_hangup", []),
  {stop, call_hangup, State};

handle_info(Info, StateName, State) ->
  lager:info("Received Info ~p", [Info]),
  {next_state, StateName, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, StateName, State) -> void()
%% Description:This function is called by a gen_fsm when it is about
%% to terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_fsm terminates with
%% Reason. The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _StateName, #state{
        uuid=UUID, conn=Conn} = _State) ->
  ouc_update(Conn, ?EVENT_KEY, UUID, [{state, stopped}]),
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
case_event_name([UUID| EventPropList], StateName, State) ->
    lager:info("In case event", []),
    Ename = case proplists:get_value("Event-Name", EventPropList) of
        "CUSTOM" -> {"CUSTOM", proplists:get_value("Event-Subclass", EventPropList)};
        Else -> Else
    end,
    lager:info("Event ~p for ~p ", [Ename, UUID]),
    case_event_name(Ename, UUID, StateName, State).

case_event_name("CHANNEL_PARK", _UUID, StateName, State) ->
    {next_state, StateName, State};

case_event_name(_Other, _UUID, StateName, State) ->
    lager:info("In case event/4", []),
    {next_state, StateName, State}.

ouc_update(Conn, Event, CallId, Data) ->
  Conn ! {Event, {l2b(CallId), Data}}.