#include <grpc/grpc.h>
#include <grpc/grpc_security.h>
#include <grpc/credentials.h>
#include <grpc/byte_buffer_reader.h>
#include <grpc/support/time.h>
#include <string.h>
#include "control.pb-c.h"

typedef Podtest__Invoker__V1__RunLease Lease;
typedef Podtest__Invoker__V1__ArtifactDescriptor Descriptor;

void *podtest_control_open(const char *target, const char *ca, const char *cert, const char *key) {
    grpc_init();
    grpc_ssl_pem_key_cert_pair pair = {.private_key = key, .cert_chain = cert};
    grpc_channel_credentials *creds = grpc_ssl_credentials_create(ca, &pair, NULL, NULL);
    grpc_arg arg = {.type = GRPC_ARG_INTEGER, .key = GRPC_ARG_MAX_RECEIVE_MESSAGE_LENGTH, .value.integer = 65536};
    grpc_arg proxy = {.type = GRPC_ARG_INTEGER, .key = GRPC_ARG_ENABLE_HTTP_PROXY, .value.integer = 0};
    grpc_arg entries[] = {arg, proxy};
    grpc_channel_args args = {.num_args = 2, .args = entries};
    grpc_channel *channel = creds ? grpc_channel_create(target, creds, &args) : NULL;
    if (creds) grpc_channel_credentials_release(creds);
    if (!channel) grpc_shutdown();
    return channel;
}

void podtest_control_close(void *channel) {
    grpc_channel_destroy(channel);
    grpc_shutdown();
}

static int unary_wire(grpc_channel *channel, const char *method, const unsigned char *wire, size_t len, unsigned char *out, size_t *size) {
    grpc_slice bytes = grpc_slice_from_copied_buffer((const char *)wire, len);
    grpc_byte_buffer *request = grpc_raw_byte_buffer_create(&bytes, 1), *response = NULL;
    grpc_slice_unref(bytes);
    grpc_completion_queue *cq = grpc_completion_queue_create_for_next(NULL);
    gpr_timespec deadline = gpr_time_add(gpr_now(GPR_CLOCK_MONOTONIC), gpr_time_from_seconds(10, GPR_TIMESPAN));
    grpc_call *call = grpc_channel_create_call(channel, NULL, 0, cq, grpc_slice_from_static_string(method), NULL, deadline, NULL);
    grpc_metadata_array initial, trailing;
    grpc_metadata_array_init(&initial);
    grpc_metadata_array_init(&trailing);
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
    int rc = -1;
    if (grpc_call_start_batch(call, ops, sizeof(ops) / sizeof(*ops), call, NULL) == GRPC_CALL_OK) {
        grpc_event event = grpc_completion_queue_next(cq, gpr_inf_future(GPR_CLOCK_MONOTONIC), NULL);
        if (event.type == GRPC_OP_COMPLETE && event.success) {
            if (status != GRPC_STATUS_OK) rc = status;
            else if (response && grpc_byte_buffer_length(response) <= *size) {
                grpc_byte_buffer_reader reader;
                if (grpc_byte_buffer_reader_init(&reader, response)) {
                    bytes = grpc_byte_buffer_reader_readall(&reader);
                    *size = GRPC_SLICE_LENGTH(bytes);
                    memcpy(out, GRPC_SLICE_START_PTR(bytes), *size);
                    grpc_slice_unref(bytes);
                    grpc_byte_buffer_reader_destroy(&reader);
                    rc = 0;
                }
            }
        }
    }
    grpc_slice_unref(details);
    grpc_metadata_array_destroy(&initial);
    grpc_metadata_array_destroy(&trailing);
    if (response) grpc_byte_buffer_destroy(response);
    grpc_byte_buffer_destroy(request);
    grpc_call_unref(call);
    grpc_completion_queue_shutdown(cq);
    grpc_completion_queue_next(cq, gpr_inf_future(GPR_CLOCK_MONOTONIC), NULL);
    grpc_completion_queue_destroy(cq);
    return rc;
}

static int unary(grpc_channel *channel, const char *method, ProtobufCMessage *message, unsigned char *out, size_t *size) {
    unsigned char wire[4096];
    if (protobuf_c_message_get_packed_size(message) > sizeof(wire)) return -1;
    size_t len = protobuf_c_message_pack(message, wire);
    return unary_wire(channel, method, wire, len, out, size);
}

struct identity { char *invoker, *epoch, *attempt, *run; unsigned char token[32]; };
struct claim_result { int64_t expires; unsigned char token[32], source_sha[32], bundle_sha[32]; uint64_t source_size, bundle_size; char source[16385], bundle[16385]; };
struct upload_result { int64_t expires; int complete; char id[121], url[16385], checksum[45], length[21]; };
struct renewed_result { int64_t expires; };

static Lease lease_for(struct identity *id) {
    Lease lease = PODTEST__INVOKER__V1__RUN_LEASE__INIT;
    lease.invoker_id = id->invoker; lease.process_epoch = id->epoch;
    lease.attempt_id = id->attempt; lease.run_id = id->run;
    lease.fencing_token = (ProtobufCBinaryData){32, id->token};
    return lease;
}

static int copy(char *dest, size_t cap, const char *str) {
    size_t n = strlen(str);
    if (n >= cap) return 0;
    memcpy(dest, str, n + 1);
    return 1;
}

#define METHOD(name) "/podtest.invoker.v1.Control/" name
int podtest_control_claim(void *channel, struct identity *id, int refresh, struct claim_result *out) {
    unsigned char wire[65536]; size_t n = sizeof(wire);
    Lease lease = lease_for(id);
    Podtest__Invoker__V1__ClaimRequest claim = PODTEST__INVOKER__V1__CLAIM_REQUEST__INIT;
    claim.invoker_id = id->invoker; claim.process_epoch = id->epoch;
    claim.attempt_id = id->attempt; claim.run_id = id->run;
    int rc = refresh ? unary(channel, METHOD("RefreshArtifacts"), &lease.base, wire, &n)
                     : unary(channel, METHOD("Claim"), &claim.base, wire, &n);
    if (rc) return rc;
    Podtest__Invoker__V1__ClaimResponse *r = podtest__invoker__v1__claim_response__unpack(NULL, n, wire);
    if (!r) return -1;
    rc = -1;
    if (r->source && r->bundle && r->source->sha256.len == 32 && r->bundle->sha256.len == 32 && r->fencing_token.len == 32 &&
        copy(out->source, sizeof(out->source), r->source_url) && copy(out->bundle, sizeof(out->bundle), r->bundle_url) && out->source[0] && out->bundle[0]) {
        out->expires = r->lease_expires_unix;
        memcpy(out->token, r->fencing_token.data, 32);
        memcpy(out->source_sha, r->source->sha256.data, 32);
        memcpy(out->bundle_sha, r->bundle->sha256.data, 32);
        out->source_size = r->source->size_bytes; out->bundle_size = r->bundle->size_bytes;
        rc = 0;
    }
    podtest__invoker__v1__claim_response__free_unpacked(r, NULL);
    return rc;
}

int podtest_control_heartbeat(void *channel, const char *invoker, uint32_t protocol, uint32_t capacity, uint32_t load, const char *formats) {
    Podtest__Invoker__V1__HeartbeatRequest req = PODTEST__INVOKER__V1__HEARTBEAT_REQUEST__INIT;
    char *items[2]; size_t count = 0;
    char copy[64]; size_t len = strlen(formats);
    if (len >= sizeof(copy)) return -1;
    memcpy(copy, formats, len + 1);
    char *save = NULL;
    for (char *item = strtok_r(copy, ",", &save); item && count < 2; item = strtok_r(NULL, ",", &save)) items[count++] = item;
    req.invoker_id = (char *)invoker; req.protocol_version = protocol; req.capacity = capacity; req.load = load;
    req.execution_formats = items; req.n_execution_formats = count;
    unsigned char wire[128]; size_t n = sizeof(wire);
    Podtest__Invoker__V1__Acknowledgement *ack = NULL;
    int rc = unary(channel, METHOD("Heartbeat"), &req.base, wire, &n);
    if (!rc) ack = podtest__invoker__v1__acknowledgement__unpack(NULL, n, wire);
    if (!ack && !rc) rc = -1;
    if (ack) podtest__invoker__v1__acknowledgement__free_unpacked(ack, NULL);
    return rc;
}

int podtest_control_create(void *channel, struct identity *id, char *client, char *kind, uint64_t size, unsigned char *sha, struct upload_result *out) {
    Lease lease = lease_for(id);
    Descriptor descriptor = PODTEST__INVOKER__V1__ARTIFACT_DESCRIPTOR__INIT;
    descriptor.sha256 = (ProtobufCBinaryData){32, sha}; descriptor.size_bytes = size;
    Podtest__Invoker__V1__CreateArtifactUploadRequest req = PODTEST__INVOKER__V1__CREATE_ARTIFACT_UPLOAD_REQUEST__INIT;
    req.lease = &lease; req.client_artifact_id = client; req.kind = kind; req.artifact = &descriptor;
    unsigned char wire[65536]; size_t n = sizeof(wire);
    int rc = unary(channel, METHOD("CreateArtifactUpload"), &req.base, wire, &n);
    if (rc) return rc;
    Podtest__Invoker__V1__ArtifactUploadTarget *r = podtest__invoker__v1__artifact_upload_target__unpack(NULL, n, wire);
    if (!r) return -1;
    memset(out, 0, sizeof(*out));
    int valid = copy(out->id, sizeof(out->id), r->artifact_id) && out->id[0] && copy(out->url, sizeof(out->url), r->put_url);
    out->expires = r->expires_at_unix_millis; out->complete = r->complete;
    if (r->complete) valid = valid && !out->url[0] && !r->n_required_headers;
    else {
        valid = valid && out->url[0] && r->n_required_headers == 2;
        for (size_t i = 0; valid && i < r->n_required_headers; ++i) {
            const Podtest__Invoker__V1__ArtifactUploadTarget__RequiredHeadersEntry *h = r->required_headers[i];
            if (!strcmp(h->key, "x-amz-checksum-sha256") && !out->checksum[0]) valid = copy(out->checksum, sizeof(out->checksum), h->value);
            else if (!strcmp(h->key, "content-length") && !out->length[0]) valid = copy(out->length, sizeof(out->length), h->value);
            else valid = 0;
        }
        valid = valid && out->checksum[0] && out->length[0];
    }
    podtest__invoker__v1__artifact_upload_target__free_unpacked(r, NULL);
    return valid ? 0 : -1;
}

int podtest_control_complete(void *channel, struct identity *id, char *artifact) {
    Lease lease = lease_for(id);
    Podtest__Invoker__V1__CompleteArtifactUploadRequest req = PODTEST__INVOKER__V1__COMPLETE_ARTIFACT_UPLOAD_REQUEST__INIT;
    req.lease = &lease; req.artifact_id = artifact;
    unsigned char wire[256]; size_t n = sizeof(wire);
    int rc = unary(channel, METHOD("CompleteArtifactUpload"), &req.base, wire, &n);
    if (rc) return rc;
    Podtest__Invoker__V1__Acknowledgement *ack = podtest__invoker__v1__acknowledgement__unpack(NULL, n, wire);
    if (!ack) return -1;
    podtest__invoker__v1__acknowledgement__free_unpacked(ack, NULL);
    return 0;
}

static size_t encode_event(Podtest__Invoker__V1__Event event, struct identity *id, char *submission,
        unsigned char event_id[16], uint64_t sequence, int64_t timestamp, unsigned char *out, size_t capacity) {
    event.event_id = (ProtobufCBinaryData){16, event_id};
    event.attempt_id = id->attempt;
    event.run_id = id->run;
    event.invoker_id = id->invoker;
    event.fencing_token = (ProtobufCBinaryData){32, id->token};
    event.submission_id = submission;
    event.sequence = sequence;
    event.schema_version = 1;
    event.occurred_at_unix_millis = timestamp;
    if (podtest__invoker__v1__event__get_packed_size(&event) > capacity) return 0;
    return podtest__invoker__v1__event__pack(&event, out);
}

size_t podtest_encode_artifact_event(struct identity *id, char *submission, char *artifact,
        unsigned char event_id[16], uint64_t sequence, int64_t timestamp, unsigned char *out, size_t capacity) {
    Podtest__Invoker__V1__Event event = PODTEST__INVOKER__V1__EVENT__INIT;
    event.kind = PODTEST__INVOKER__V1__EVENT__KIND__ARTIFACT_CREATED;
    event.artifact_id = artifact;
    return encode_event(event, id, submission, event_id, sequence, timestamp, out, capacity);
}

struct result_fields { char *test_id, *subgroup_id, *verdict, *score, *outcome; };

size_t podtest_encode_result_event(struct identity *id, char *submission, const struct result_fields *fields,
        unsigned char event_id[16], uint64_t sequence, int64_t timestamp, unsigned char *out, size_t capacity) {
    Podtest__Invoker__V1__Event event = PODTEST__INVOKER__V1__EVENT__INIT;
    if (fields->outcome) {
        event.kind = PODTEST__INVOKER__V1__EVENT__KIND__RUN_FINISHED;
        event.outcome = fields->outcome;
    } else {
        event.score_presence_case = PODTEST__INVOKER__V1__EVENT__SCORE_PRESENCE_SCORE;
        event.score = fields->score;
        if (fields->test_id) {
            event.kind = PODTEST__INVOKER__V1__EVENT__KIND__TEST_FINISHED;
            event.test_id = fields->test_id;
        } else if (fields->subgroup_id) {
            event.kind = PODTEST__INVOKER__V1__EVENT__KIND__SUBGROUP_SCORE;
            event.subgroup_id = fields->subgroup_id;
        } else {
            event.kind = PODTEST__INVOKER__V1__EVENT__KIND__PROBLEM_SCORE;
        }
    }
    if (fields->verdict) event.verdict = fields->verdict;
    return encode_event(event, id, submission, event_id, sequence, timestamp, out, capacity);
}

int podtest_matches_artifact_event(const unsigned char *wire, size_t len, const char *artifact) {
    Podtest__Invoker__V1__Event *event = podtest__invoker__v1__event__unpack(NULL, len, wire);
    if (!event) return -1;
    int match = event->kind == PODTEST__INVOKER__V1__EVENT__KIND__ARTIFACT_CREATED && !strcmp(event->artifact_id, artifact);
    podtest__invoker__v1__event__free_unpacked(event, NULL);
    return match;
}

int podtest_control_report(void *channel, const unsigned char *wire, size_t len) {
    if (!len || len > 4096) return -1;
    unsigned char response[128]; size_t response_len = sizeof(response);
    int rc = unary_wire(channel, METHOD("Report"), wire, len, response, &response_len);
    if (rc) return rc;
    Podtest__Invoker__V1__Acknowledgement *ack = podtest__invoker__v1__acknowledgement__unpack(NULL, response_len, response);
    if (!ack) return -1;
    podtest__invoker__v1__acknowledgement__free_unpacked(ack, NULL);
    return 0;
}

int podtest_control_renew(void *channel, struct identity *id, struct renewed_result *out) {
    Lease lease = lease_for(id);
    unsigned char response[128]; size_t n = sizeof(response);
    int rc = unary(channel, METHOD("RenewLease"), &lease.base, response, &n);
    if (rc) return rc;
    Podtest__Invoker__V1__RenewLeaseResponse *decoded = podtest__invoker__v1__renew_lease_response__unpack(NULL, n, response);
    if (!decoded) return -1;
    out->expires = decoded->lease_expires_unix;
    podtest__invoker__v1__renew_lease_response__free_unpacked(decoded, NULL);
    return out->expires > 0 ? 0 : -1;
}
