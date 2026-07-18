#include <stdio.h>

#include "rn_async_state.h"

static int
expect(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL async state: %s\n", message);
        return 1;
    }
    return 0;
}

int
main(void)
{
    rn_async_state_t state = {0};

    rn_async_state_begin(&state);
    if (expect(rn_async_state_is_starting(&state),
            "begin did not mark the start call active")
        || expect(rn_async_state_finish(&state, 1) == 1,
            "successful asynchronous start was not published")
        || expect(!rn_async_state_is_starting(&state),
            "finish left the start call active"))
    {
        return 1;
    }

    rn_async_state_begin(&state);
    rn_async_state_complete(&state);
    if (expect(rn_async_state_is_starting(&state),
            "synchronous completion lost the reentrancy guard")
        || expect(rn_async_state_finish(&state, 1) == 0,
            "synchronous completion was published as pending"))
    {
        return 1;
    }

    rn_async_state_begin(&state);
    if (expect(rn_async_state_finish(&state, 0) == 0,
            "failed start was published as pending"))
    {
        return 1;
    }

    rn_async_state_begin(NULL);
    rn_async_state_complete(NULL);
    if (expect(rn_async_state_finish(NULL, 1) == 0,
            "null state was published as pending"))
    {
        return 1;
    }

    puts("PASS asynchronous start state");
    return 0;
}
