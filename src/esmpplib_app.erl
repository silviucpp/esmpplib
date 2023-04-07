-module(esmpplib_app).

-behaviour(application).

-export([
    start/2,
    stop/1
]).

start(_StartType, _StartArgs) ->
    ok = start_pools(),
    esmpplib_sup:start_link().

stop(_State) ->
    ok.

% internals

start_pools() ->
    Pools = get_pools(),

    Fun = fun({PoolName, PoolConfig}) ->
        PoolSize = esmpplib_utils:lookup(size, PoolConfig, 1),
        ConnectionOptions0 = maps:from_list(esmpplib_utils:lookup(connection_options, PoolConfig)),
        ConnectionOptions = maps:put(id, PoolName, ConnectionOptions0),

        ok = erlpool:start_pool(PoolName, [
            {size, PoolSize},
            {group, esmpplib_connection_pool},
            {start_mfa, {esmpplib_connection, start_link, [ConnectionOptions]}}
        ])
    end,
    lists:foreach(Fun, Pools).

get_pools() ->
    case esmpplib_utils:get_env(pools) of
        null ->
            [];
        Value ->
            Value
    end.
