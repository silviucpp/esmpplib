-module(ect_event_manager).

-include("esmpplib.hrl").

-behaviour(gen_server).

-export([

    start_link/0,
    register_handler/2,
    unregister_handler/2,
    notify/2,
    registered_events_count/0,
    is_empty/0,

    % gen_server

    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    handlers_map
}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

register_handler(EventName, Fun) ->
    gen_server:call(?MODULE, {register_handler, EventName, Fun}, infinity).

unregister_handler(EventName, Fun) ->
    gen_server:call(?MODULE, {unregister_handler, EventName, Fun}, infinity).

notify(EventName, Args) ->
    gen_server:call(?MODULE, {notify, EventName, Args}, infinity).

registered_events_count() ->
    gen_server:call(?MODULE, registered_events_count, infinity).

is_empty() ->
    gen_server:call(?MODULE, is_empty, infinity).

init([]) ->
    {ok, #state{handlers_map = maps:new()}}.

handle_call({notify, EventName, Args}, _From, #state{handlers_map = Hmap} = State) ->

    case maps:find(EventName, Hmap) of
        {ok, HandlersList} ->
            ?INFO_MSG("### notify: ~p (~p) execute in ~p handlers", [EventName, Args, length(HandlersList)]),

            Fun = fun(Handler, _LastResult) ->
                try
                    Handler(EventName, Args)
                catch
                    ?EXCEPTION(_, Error, Stacktrace)  ->
                        ?INFO_MSG("### notify: ~p handler crashed: ~p stack: ~p", [EventName, Error, ?GET_STACK(Stacktrace)]),
                        ok
                end
                  end,
            LastRes = lists:foldl(Fun, ok, HandlersList),
            {reply, LastRes, State};
        error ->
            ?INFO_MSG("### notify: ~p (~p). no handler registered", [EventName, Args]),
            {reply, ok, State}
    end;

handle_call({register_handler, EventName, Fun}, _From, #state{handlers_map = Hmap} = State) ->

    ?INFO_MSG("### register_handler: ~p fun: ~p", [EventName, Fun]),

    case maps:find(EventName, Hmap) of
        {ok, HandlersList} ->
            {reply, ok, State#state{handlers_map = maps:put(EventName, [Fun| HandlersList], Hmap)}};
        error ->
            {reply, ok, State#state{handlers_map = maps:put(EventName, [Fun], Hmap)}}
    end;

handle_call({unregister_handler, EventName, Fun}, _From, #state{handlers_map = Hmap} = State) ->

    ?INFO_MSG("### unregister_handler: ~p fun: ~p", [EventName, Fun]),

    case maps:find(EventName, Hmap) of
        {ok, HandlersList} ->
            case lists:delete(Fun, HandlersList) of
                [] ->
                    {reply, ok, State#state{handlers_map = maps:remove(EventName, Hmap)}};
                RemainingHandlers ->
                    {reply, ok, State#state{handlers_map = maps:put(EventName, RemainingHandlers, Hmap)}}
            end;
        error ->
            {reply, not_found, State}
    end;

handle_call(registered_events_count, _From, #state{handlers_map = Hmap} = State) ->
    {reply, maps:size(Hmap), State};

handle_call(is_empty, _From, #state{handlers_map = Hmap} = State) ->
    case maps:size(Hmap) > 0 of
        true ->
            {reply, {false, maps:keys(Hmap)}, State};
        _ ->
            {reply, true, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
