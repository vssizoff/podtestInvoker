#include <grpc/grpc.h>
#include <grpc/grpc_security.h>
#include <grpc/grpc_security_constants.h>
#include <grpc/credentials.h>
#include <grpc/byte_buffer_reader.h>
#include <string.h>

// Single, bounded plaintext test call to the loopback Go process.
int rpc(const char *target, const char *method, const unsigned char *payload,
        size_t length, unsigned char *out, size_t max, size_t *written) {
    int result = -1;
    grpc_init();
    grpc_channel_credentials *credentials = grpc_insecure_credentials_create();
    grpc_channel *channel = grpc_channel_create(target, credentials, NULL);
    grpc_channel_credentials_release(credentials);
    grpc_completion_queue *cq = grpc_completion_queue_create_for_next(NULL);
    gpr_timespec deadline = gpr_time_add(gpr_now(GPR_CLOCK_MONOTONIC), gpr_time_from_seconds(2, GPR_TIMESPAN));
    grpc_slice name = grpc_slice_from_static_string(method);
    grpc_call *call = grpc_channel_create_call(channel, NULL, 0, cq, name, NULL, deadline, NULL);
    grpc_slice slice = grpc_slice_from_copied_buffer((const char *)payload, length);
    grpc_byte_buffer *request = grpc_raw_byte_buffer_create(&slice, 1);
    grpc_slice_unref(slice);
    grpc_metadata_array initial, trailing;
    grpc_metadata_array_init(&initial);
    grpc_metadata_array_init(&trailing);
    grpc_byte_buffer *response = NULL;
    grpc_status_code status = GRPC_STATUS_UNKNOWN;
    grpc_slice details = grpc_empty_slice();
    grpc_op ops[] = {
        {.op = GRPC_OP_SEND_INITIAL_METADATA},
        {.op = GRPC_OP_SEND_MESSAGE, .data.send_message.send_message = request},
        {.op = GRPC_OP_SEND_CLOSE_FROM_CLIENT},
        {.op = GRPC_OP_RECV_INITIAL_METADATA, .data.recv_initial_metadata.recv_initial_metadata = &initial},
        {.op = GRPC_OP_RECV_MESSAGE, .data.recv_message.recv_message = &response},
        {.op = GRPC_OP_RECV_STATUS_ON_CLIENT, .data.recv_status_on_client = {
            .trailing_metadata = &trailing, .status = &status, .status_details = &details}},
    };
    if (grpc_call_start_batch(call, ops, sizeof(ops) / sizeof(ops[0]), call, NULL) == GRPC_CALL_OK) {
        grpc_event event = grpc_completion_queue_next(cq, gpr_inf_future(GPR_CLOCK_MONOTONIC), NULL);
        if (event.type == GRPC_OP_COMPLETE && event.success) {
            if (status != GRPC_STATUS_OK) result = status;
            else if (response && grpc_byte_buffer_length(response) <= max) {
                grpc_byte_buffer_reader reader;
                if (grpc_byte_buffer_reader_init(&reader, response)) {
                    grpc_slice bytes = grpc_byte_buffer_reader_readall(&reader);
                    *written = GRPC_SLICE_LENGTH(bytes);
                    memcpy(out, GRPC_SLICE_START_PTR(bytes), *written);
                    grpc_slice_unref(bytes);
                    grpc_byte_buffer_reader_destroy(&reader);
                    result = 0;
                }
            }
        }
    }
    grpc_slice_unref(details);
    grpc_metadata_array_destroy(&trailing);
    grpc_metadata_array_destroy(&initial);
    if (response) grpc_byte_buffer_destroy(response);
    grpc_byte_buffer_destroy(request);
    grpc_call_unref(call);
    grpc_channel_destroy(channel);
    grpc_completion_queue_shutdown(cq);
    grpc_completion_queue_next(cq, gpr_inf_future(GPR_CLOCK_MONOTONIC), NULL);
    grpc_completion_queue_destroy(cq);
    grpc_shutdown();
    return result;
}
