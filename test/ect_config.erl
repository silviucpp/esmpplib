-module(ect_config).

-behaviour(gen_server).

-export([
    % api

    start/0,
    stop/0,
    set/1,
    set/2,
    get/1,
    delete/1,

    % gen_server callbacks

    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    map
}).

start() ->
    {ok, _} = gen_server:start({local, ?MODULE}, ?MODULE, [], []),
    ok.

stop() ->
    gen_server:stop(?MODULE).

delete(Key) ->
    safe_call(?MODULE, {delete, Key}).

set(Key, Value) ->
    safe_call(?MODULE, {set, Key, Value}).

set(List) when is_list(List) ->
    safe_call(?MODULE, {set, List}).

get(Key) ->
    safe_call(?MODULE, {get, Key}).

% gen_server

init([]) ->
    {ok, #state{map = #{}}}.

handle_call({get, Key}, _From, #state{map = Map} = State) ->
    {reply, maps:get(Key, Map, null), State};
handle_call({set, K, V}, _From, #state{map = Map} = State) ->
    {reply, ok, State#state{map = maps:put(K, V, Map)}};
handle_call({set, List}, _From, #state{map = Map} = State) ->
    NewMap = lists:foldl(fun({K,V}, M) -> maps:put(K, V, M) end, Map, List),
    {reply, ok, State#state{map = NewMap}};
handle_call({delete, Key}, _From, #state{map = Map} = State) ->
    {reply, ok, State#state{map = maps:remove(Key, Map)}}.
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

% internals

safe_call(Receiver, Message) ->
    safe_call(Receiver, Message, 5000).

safe_call(Receiver, Message, Timeout) ->
    try
        gen_server:call(Receiver, Message, Timeout)
    catch
        exit:{noproc, _} ->
            {error, not_started};
        _: Exception ->
            {error, Exception}
    end.
