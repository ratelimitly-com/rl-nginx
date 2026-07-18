#include "rn_async_state.h"

#include <stddef.h>

void
rn_async_state_begin(rn_async_state_t *state)
{
    if (state == NULL) {
        return;
    }
    state->starting = 1;
    state->completed = 0;
}

void
rn_async_state_complete(rn_async_state_t *state)
{
    if (state == NULL) {
        return;
    }
    state->completed = 1;
}

int
rn_async_state_is_starting(const rn_async_state_t *state)
{
    return state != NULL && state->starting;
}

int
rn_async_state_finish(rn_async_state_t *state, int start_succeeded)
{
    int pending;

    if (state == NULL) {
        return 0;
    }
    pending = start_succeeded && !state->completed;
    state->starting = 0;
    return pending;
}
