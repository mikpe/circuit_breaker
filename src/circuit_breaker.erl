%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc Circuit breaker
%%%
%%% Generic circuit breaker that can be used to break any service that
%%% isn't fully functional. A service can be manually blocked/cleared as well.
%%% The service will be executed in a spawned process that will continue
%%% execution even after a specified call timeout in order to be able
%%% to complete a request even if a response is not sent to the client.
%%% NOTE: It's important that the service can store it's result even
%%% if the result is not returned to the client.
%%%
%%% Information regarding current services under circuit breaker
%%% control can be displayed by: circuit_breaker:info/0.
%%%
%%% The circuit breaker generates an error event if a service is
%%% automatically blocked due to too many errors/timeouts.
%%% An info event is sent when the service is automatically cleared again.
%%%
%%% If several services are used to provide functionallity it's
%%% outside the scope of this server to take care (e.g. send
%%% a critical event) in the case that all used services are
%%% blocked.
%%%
%%% The heuristics/thresholds are configurable per service.
%%%
%%% @author Christian Rennerskog <christian.r@klarna.com>
%%% @author Magnus Fr�berg <magnus@klarna.com>
%%% @copyright 2012 Klarna AB
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration ===============================================
-module(circuit_breaker).

%%%_* Behaviour ========================================================
-behaviour(gen_server).

%%%_* Exports ==========================================================
%% API
-export([ start_link/0
        , call/2
        , call/5
        , call/6
        , clear/1
        , block/1
        , deblock/1
        , active/1
        , blocked/1
        , info/0
        ]).

%% Gen server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

%%%_* Includes =========================================================
-include("circuit_breaker.hrl").

%%%_* Records ==========================================================
-record(state, {}).
-record(circuit_breaker
        { service                            % Term, e.g. {IP|Host, Port}
        , flags        = ?CIRCUIT_BREAKER_OK % Status flags, ?CIRCUIT_BREAKER_*
        , timeout      = 0                   % {N, gnow()} | 0
        , call_timeout = 0                   % {N, gnow()} | 0
        , error        = 0                   % {N, gnow()} | 0
        , reset_fun                          % Fun to check for up status
        , ref                                % Timer reference
        }).

%%%_* Defines ==========================================================
-define(SERVER,        ?MODULE).
-define(TABLE,         ?MODULE).
-define(CALL_TIMEOUT,  10 * 1000).         % 10 seconds
-define(RESET_TIMEOUT, 10 * 60 * 1000).    % 10 minutes.
-define(RESET_FUN,     fun() -> true end).

%%%_* API ==============================================================
-spec start_link() -> {ok, Pid::pid()} | ignore | {error, Reason::term()}.
%% @doc Start circuit_breaker.
%% @end
start_link() -> gen_server:start_link({local, ?SERVER}, ?SERVER, [], []).

-spec call(Service::term(), CallFun::function()) -> ok.
%% @doc Call Service with default parameters.
%% @end
call(Service, CallFun) ->
  call(Service, CallFun, ?CALL_TIMEOUT, ?RESET_FUN, ?RESET_TIMEOUT).

-spec call(Service::term(), CallFun::function(), CallTimeout::integer(),
           ResetFun::function(), ResetTimeout::integer()) -> ok.
%% @doc Call Service with custom parameters.
%% @end
call(Service, CallFun, CallTimeout, ResetFun, ResetTimeout) ->
  case read(Service) of
    R when (R#circuit_breaker.flags > ?CIRCUIT_BREAKER_WARNING) ->
      {error, {circuit_breaker, R#circuit_breaker.flags}};
    _ -> do_call(Service, CallFun, CallTimeout, ResetFun, ResetTimeout)
  end.

%%%_* Gen server callbacks =============================================
%% @hidden
init([]) ->
  ?TABLE = ets:new(?TABLE, [named_table, {keypos, #circuit_breaker.service}]),
  {ok, #state{}}.

%% @hidden
handle_call({init, Service}, _From, State) ->
  do_init(Service),
  {reply, ok, State};
handle_call({change_status, Service, What}, _From, State) ->
  do_change_status(Service, What),
  {reply, ok, State}.

%% @hidden
handle_cast(_Msg, State) -> {noreply, State}.

%% @hidden
handle_info({reset, Service, ResetTimeout}, State) ->
  reset_service(Service, ResetTimeout),
  {noreply, State};

%% @hidden
handle_info(_Info, State) -> {noreply, State}.

%% @hidden
terminate(_Reason, _State) -> ok.

%% @hidden
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%_* Internal =========================================================
%%%_* ETS operations ---------------------------------------------------
read(Service) ->
  case ets:lookup(?TABLE, Service) of
    [R] -> R;
    []  -> #circuit_breaker{service = Service}
  end.

try_read(Service) ->
  case ets:lookup(?TABLE, Service) of
    [R] -> {ok, R};
    []  -> false
  end.

exists(Service) -> ets:lookup(?TABLE, Service) =/= [].

write(#circuit_breaker{} = R) -> ets:insert(?TABLE, R).

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
