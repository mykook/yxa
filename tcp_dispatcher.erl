%%%-------------------------------------------------------------------
%%% File    : tcp_dispatcher.erl
%%% Author  : Fredrik Thulin <ft@it.su.se>
%%% Descrip.: TCP dispatcher initially does gen_tcp:listen() and
%%%           then keeps track of all existing TCP connections.
%%%
%%% Created : 12 Mar 2004 by Fredrik Thulin <ft@it.su.se>
%%%-------------------------------------------------------------------
-module(tcp_dispatcher).

-behaviour(gen_server).

%%--------------------------------------------------------------------
%% External exports
%%--------------------------------------------------------------------
-export([start_link/0]).

%%--------------------------------------------------------------------
%% Transport layer internal exports
%%--------------------------------------------------------------------
-export([
	 get_listenerspecs/0
	]).

%%--------------------------------------------------------------------
%% Internal exports - gen_server callbacks
%%--------------------------------------------------------------------
-export([init/1,
	 handle_call/3,
	 handle_cast/2,
	 handle_info/2,
	 terminate/2,
	 code_change/3]).

%%--------------------------------------------------------------------
%% Include files
%%--------------------------------------------------------------------

-include("socketlist.hrl").
-include("sipsocket.hrl").

%%--------------------------------------------------------------------
%% Records
%%--------------------------------------------------------------------

-record(state, {
	  socketlist	%% Our list of existing TCP connections
	 }).

%%--------------------------------------------------------------------
%% Macros
%%--------------------------------------------------------------------

%% Our standard wakeup interval - how often we should look for expired
%% entrys in our socketlist.
-define(TIMEOUT, 10 * 1000).

%%====================================================================
%% External functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: start_link()
%% Descrip.: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, tcp_dispatcher}, ?MODULE, [], []).

%%====================================================================
%% Behaviour functions
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init([])
%% Descrip.: Initiates the server
%% Returns : {ok, State}          |
%%           {ok, State, Timeout} |
%%           ignore               |
%%           {stop, Reason}
%%--------------------------------------------------------------------
init([]) ->
    %% This is a system process that traps EXIT signals from TCP/TLS connection handlers
    process_flag(trap_exit, true),
    {ok, #state{socketlist=socketlist:empty()}, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: get_listenerspecs()
%% Descrip.: Get a OTP supservisor child specification for all TCP
%%           listeners.
%% Returns : SupSpec
%%           SupSpec = OTP supervisor child specification. Extra
%%                     processes this application want the
%%                     sipserver_sup to start and maintain.
%%--------------------------------------------------------------------
get_listenerspecs() ->
    Port = sipserver:get_listenport(tcp),
    TLSport = sipserver:get_listenport(tls),
    TCPlisteners = [{tcp, Port}, {tcp6, Port}],
    Listeners = case sipserver:get_env(enable_experimental_tls, false) of
		    true ->
			%% XXX add tls6 to this list when there is an Erlang version released
			%% than has a ssl.erl that handles inet6. Current version (R9C-0) treats
			%% inet6 as an invalid gen_tcp option.
			lists:append(TCPlisteners, [{tls, TLSport}]);
		    false ->
			TCPlisteners
		end,
    format_listener_specs(Listeners).

%%--------------------------------------------------------------------
%% Function: format_listener_specs(L)
%%           L     = list() of {Proto, Port} tuple()
%%           Proto = atom()
%%           Port  = integer()
%% Descrip.: Format a OTP supservisor child specification for each
%%           entry in L.
%% Returns : SupSpec
%%           SupSpec = OTP supervisor child specification. Extra
%%                     processes this application want the
%%                     sipserver_sup to start and maintain.
%%--------------------------------------------------------------------
format_listener_specs(L) ->
    format_listener_specs(L, []).

format_listener_specs([], Res) ->
    lists:reverse(Res);
format_listener_specs([{Proto, Port} | T], Res)
  when is_atom(Proto), is_integer(Port), Proto == tcp6; Proto == tls6 ->
    case sipserver:get_env(enable_v6, false) of
	true ->
	    Id = {listener, Proto, Port},
	    MFA = {tcp_listener, start_link, [Proto, Port]},
	    Spec = {Id, MFA, permanent, brutal_kill, worker, [tcp_listener]},
	    format_listener_specs(T, [Spec | Res]);
	false ->
	    format_listener_specs(T, Res)
    end;
format_listener_specs([{Proto, Port} | T], Res)
  when is_atom(Proto), is_integer(Port), Proto == tcp; Proto == tls ->
    Id = {listener, Proto, Port},
    MFA = {tcp_listener, start_link, [Proto, Port]},
    Spec = {Id, MFA, permanent, brutal_kill, worker, [tcp_listener]},
    format_listener_specs(T, [Spec | Res]).


%%--------------------------------------------------------------------
%% Function: handle_call(Msg, From, State)
%% Descrip.: Handling call messages
%% Returns : {reply, Reply, State}          |
%%           {reply, Reply, State, Timeout} |
%%           {noreply, State}               |
%%           {noreply, State, Timeout}      |
%%           {stop, Reason, Reply, State}   | (terminate/2 is called)
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: handle_call({get_socket, Proto, Host, Port}, From, State)
%%           Proto = atom(), tcp | tcp6 | tls
%%           Host  = string()
%%           Port  = integer()
%% Descrip.: Look for a cached connection to Proto:Host:Port. If one
%%           is found, return {reply, ...} with it. Else, start a
%%           tcp_connection process that tries to connect to the
%%           Proto:Host:Port and will do gen_server:reply(...) when it
%%           either succeeds or fails. We must do it this way since we
%%           can't block the tcp_dispatcher process. There is a race
%%           here where we might end up having more than one
%%           connection to Proto:Host:Port at the same time, but that
%%           should be OK.
%% Returns : {reply, Reply, NewState, ?TIMEOUT} |
%%           {noreply, NewState, ?TIMEOUT}
%%           Reply = {ok, SipSocket} |
%%                   {error, Reason}
%%           SipSocket = sipsocket record()
%%           Reason    = string()
%%--------------------------------------------------------------------
handle_call({get_socket, Proto, Host, Port}, From, State) when is_atom(Proto), is_list(Host), is_integer(Port) ->
    case get_socket_from_list(Proto, Host, Port, State#state.socketlist) of
	none ->
	    %% We must spawn a tcp_connection process to take care of making this new connection
	    %% since the tcp_dispatcher may not be blocked by time consuming operations
	    CH = tcp_connection:start_link(connect, Proto, Host, Port, From),
	    logger:log(debug, "Sipsocket TCP: No cached connection to remote host ~p:~s:~p, trying to connect "
		       "(started connection handler ~p)", [Proto, Host, Port, CH]),
	    {noreply, State, ?TIMEOUT};
	{error, E} ->
	    {reply, {error, E}, State, ?TIMEOUT};
	SipSocket when is_record(SipSocket, sipsocket) ->
	    logger:log(debug, "Sipsocket TCP: Use existing connection to ~p:~s:~p", [Proto, Host, Port]),
	    {reply, {ok, SipSocket}, State, ?TIMEOUT}
    end;


%%--------------------------------------------------------------------
%% Function: handle_call({register_sipsocket, Type, SipSocket}, From,
%%                       State)
%%           Type = in | out | listener, Direction (or, who initiated
%%                                                  the socket)
%%           SipSocket = sipsocket record()
%% Descrip.: Add a socket to our list. Called by tcp_connection
%%           handlers when they have established a connection (inbound
%%           or outbound).
%% Returns : {reply, Reply, NewState, ?TIMEOUT}
%%           Reply = ok              |
%%                   {error, Reason}
%%           Reason = string()
%%--------------------------------------------------------------------
handle_call({register_sipsocket, Type, SipSocket}, _From, State) when is_atom(Type), is_record(SipSocket, sipsocket) ->
    CPid = SipSocket#sipsocket.pid,
    %% Link to the connection handler to receive EXIT signals from it so that we
    %% can remove it from our list.
    case catch link(CPid) of
	true ->
	    {Local, Remote} = SipSocket#sipsocket.data,
	    Proto = SipSocket#sipsocket.proto,
	    Ident = case Type of
			listener ->
			    {_IP, Port} = Local,
			    {listener, Proto, Port};
			in ->
			    {from, Proto, Remote};
			out ->
			    {to, Proto, Remote}
		    end,
	    %% Socket expiration not implemented. Perhaps not even needed. If you are thinking of
	    %% implementing it remember that listening sockets should always have timeout 0.
	    Timeout = 0,	
	    case socketlist:add(Ident, CPid, Proto, Local, Remote, SipSocket, Timeout, State#state.socketlist) of
		{error, E} ->
		    logger:log(error, "TCP dispatcher: Failed adding ~p to socketlist", [Ident]),
		    {reply, {error, E}, State, ?TIMEOUT};
		NewSocketList1 ->
		    {reply, ok, State#state{socketlist=NewSocketList1}, ?TIMEOUT}
	    end;
	_ ->
	    {reply, {error, "Could not link to sipsocket pid"}, State, ?TIMEOUT}
    end;

%%--------------------------------------------------------------------
%% Function: handle_call({monitor_get_socketlist}, From, State)
%% Descrip.: The stack monitor is requesting our list of connections.
%% Returns : {reply, {ok, List} State, ?TIMEOUT}
%%           List = socketlist record()
%%--------------------------------------------------------------------
handle_call({monitor_get_socketlist}, _From, State) ->
    {reply, {ok, State#state.socketlist}, State, ?TIMEOUT};

handle_call({quit}, _From, State) ->
    {stop, "Asked to quit", State};

handle_call(Msg, _From, State) ->
    logger:log(error, "TCP dispatcher: Received unknown gen_server call : ~p", [Msg]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State)
%% Descrip.: Handling cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------

handle_cast(Msg, State) ->
    logger:log(error, "TCP dispatcher: Received unknown gen_server cast : ~p", [Msg]),
    {noreply, State, ?TIMEOUT}.


%%--------------------------------------------------------------------
%% Function: handle_info(Msg, State)
%% Descrip.: Handling all non call/cast messages
%% Returns : {noreply, State}          |
%%           {noreply, State, Timeout} |
%%           {stop, Reason, State}            (terminate/2 is called)
%%--------------------------------------------------------------------


%%--------------------------------------------------------------------
%% Function: handle_info(timeout, State)
%% Descrip.: Wake up and delete expired sockets from our list.
%% Returns : {reply, Reply, NewState, ?TIMEOUT} |
%%           Reply = ok              |
%%                   {error, Reason}
%%           Reason    = string()
%%--------------------------------------------------------------------
handle_info(timeout, State) ->
    %% XXX not sure we actually ever add sockets with an expire time set
    SocketList1 = socketlist:delete_expired(State#state.socketlist),
    {noreply, State#state{socketlist=SocketList1}, ?TIMEOUT};

%%--------------------------------------------------------------------
%% Function: handle_info({'EXIT', Pid, Reason}, State)
%%           Pid    = pid()
%%           Reason = normal | term()
%% Descrip.: Trap exit signals from socket handlers and act on them.
%%           Log if they exit with an error, and remove them from our
%%           list of existing sockets.
%% Returns : {noreply, NewState, ?TIMEOUT}
%%
%% Note    : XXX how should we handle the situation if it is a
%%           listener that exits?
%%--------------------------------------------------------------------
handle_info({'EXIT', Pid, Reason}, State) ->
    case Reason of
	normal -> logger:log(debug, "TCP dispatcher: Received normal exit-signal from process ~p", [Pid]);
	_ -> logger:log(error, "TCP dispatcher: =ERROR REPORT==== Received non-normal exit signal "
			"from process ~p :~n~p", [Pid, Reason])
    end,
    NewState = case socketlist:get_using_pid(Pid, State#state.socketlist) of
		   none ->
		       logger:log(error, "TCP dispatcher: Received exit signal from ~p not in my list.", [Pid]),
		       logger:log(debug, "TCP dispatcher: Socketlist is :~n~p",
				  [socketlist:debugfriendly(State#state.socketlist)]),
		       State;
		   L when is_record(L, socketlist) ->
		       NewL = socketlist:delete_using_pid(Pid, State#state.socketlist),
		       logger:log(debug, "TCP dispatcher: Deleting ~p entry(s) from socketlist :~n~p~n"
				  "(new list is ~p entry(s))", [socketlist:get_length(L),
								socketlist:debugfriendly(L),
								socketlist:get_length(NewL)]),
		       State#state{socketlist=NewL}
	       end,
    {noreply, NewState, ?TIMEOUT};

handle_info(Unknown, State) ->
    logger:log(error, "TCP dispatcher: Received unknown gen_server info : ~p", [Unknown]),
    {noreply, State, ?TIMEOUT}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State)
%% Descrip.: Shutdown the server
%% Returns : any (ignored by gen_server)
%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    case Reason of
        normal -> logger:log(error, "TCP dispatcher terminating normally");
        _ -> logger:log(error, "TCP dispatcher terminating : ~p", [Reason])
    end,
    Reason.

%%--------------------------------------------------------------------
%% Function: code_change(OldVsn, State, Extra)
%% Descrip.: Convert process state when code is changed
%% Returns : {ok, NewState}
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%%--------------------------------------------------------------------
%% Function: get_socket_from_list(Proto, Host, Port, SocketList)
%%           Proto = atom(), tcp | tcp6 | tls | tls6
%%           Host  = string()
%%           Port  = term()
%%           SocketList = socketlist record()
%% Descrip.: Look for an entry with remote {Host, Port} in SocketList
%% Returns : SipSocket |
%%           none
%%           SipSocket = sipsocket record()
%%--------------------------------------------------------------------
get_socket_from_list(Proto, Host, Port, SocketList) when is_list(Host), is_integer(Port),
							 Proto == tcp; Proto == tcp6;
							 Proto == tls; Proto == tls6 ->
    case socketlist:get_using_remote(Proto, {Host, Port}, SocketList) of
	SListElem when is_record(SListElem, socketlistelem) ->
	    [CPid, SipSocket] = socketlist:extract([pid, sipsocket], SListElem),
	    logger:log(debug, "Sipsocket TCP: Reusing existing connection to ~p:~s:~p (~p)",
		       [Proto, Host, Port, CPid]),
	    SipSocket;
	_ ->
	    none
    end.
