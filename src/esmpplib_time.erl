-module(esmpplib_time).

-export([
    now_msec/0,
    datetime2ts/1
]).

now_msec() ->
    tic:now_to_epoch_msecs().

datetime2ts(DateTime) ->
    tic:datetime_to_epoch_secs(DateTime).
