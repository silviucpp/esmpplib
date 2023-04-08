-module(ect_utils).

-export([
    wait_for_boolean_condition/2,
    wait_for_config_is_set/1,
    wait_for_config_value/2,
    wait_for_update/3
]).

wait_for_boolean_condition(_, 0) ->
    {error, <<"waiting for condition failed">>};
wait_for_boolean_condition(Fun, Retry) ->
    case Fun() of
        true ->
            ok;
        false ->
            timer:sleep(100),
            wait_for_boolean_condition(Fun, Retry -1);
        Other ->
            {error, unexpected_result, Other}
    end.

wait_for_config_is_set(ConfigProperty) ->
    case ect_config:get(ConfigProperty) of
        null ->
            timer:sleep(100),
            wait_for_config_is_set(ConfigProperty);
        _ ->
            ok
    end.

wait_for_config_value(ConfigProperty, Value) ->
    case ect_config:get(ConfigProperty) of
        Value ->
            ok;
        _ ->
            timer:sleep(100),
            wait_for_config_value(ConfigProperty, Value)
    end.

wait_for_update(_Fun, _Compare, 0) ->
    {error, wait_exceeded};
wait_for_update(Fun, Compare, Nr) ->
    Size = Fun(),
    case Size > Compare of
        true ->
            {ok, Size};
        _ ->
            timer:sleep(100),
            wait_for_update(Fun, Compare, Nr-1)
    end.
