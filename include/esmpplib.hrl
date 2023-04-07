% logs

-include_lib("kernel/include/logger.hrl").

-define(PRINT_MSG(Format, Args),
    io:format(Format, Args)).

-define(DEBUG_MSG(Format, Args),
    ?LOG_DEBUG(Format, Args)).

-define(INFO_MSG(Format, Args),
    ?LOG_INFO(Format, Args)).

-define(WARNING_MSG(Format, Args),
    ?LOG_WARNING(Format, Args)).

-define(ERROR_MSG(Format, Args),
    ?LOG_ERROR(Format, Args)).

% exceptions

-ifdef(OTP_RELEASE). %% this implies 21 or higher
-define(EXCEPTION(Class, Reason, Stacktrace), Class:Reason:Stacktrace).
-define(GET_STACK(Stacktrace), Stacktrace).
-else.
-define(EXCEPTION(Class, Reason, _), Class:Reason).
-define(GET_STACK(_), erlang:get_stacktrace()).
-endif.

-type timestamp()  :: non_neg_integer()|null.
-type msg_status() :: binary().
-type reason() :: any().
