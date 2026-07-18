#ifndef RN_ASYNC_STATE_H
#define RN_ASYNC_STATE_H

typedef struct {
    unsigned starting : 1;
    unsigned completed : 1;
} rn_async_state_t;

void rn_async_state_begin(rn_async_state_t *state);

void rn_async_state_complete(rn_async_state_t *state);

int rn_async_state_is_starting(const rn_async_state_t *state);

/*
 * Finish the call that started an operation.  Returns 1 only when the start
 * succeeded and no synchronous callback completed the operation.
 */
int rn_async_state_finish(rn_async_state_t *state, int start_succeeded);

#endif
