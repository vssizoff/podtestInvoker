package main

import (
	"context"
	"log"
	"net"
	"os"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	pb "podtest/internal/invokerpb"
)

type server struct {
	pb.UnimplementedControlServer
	pb.UnimplementedLeaseFixtureServer
	mu        sync.Mutex
	lastEvent *pb.Event
	replayed  bool
}

func fixtureLease() *pb.RunLease {
	return &pb.RunLease{InvokerId: "spike", ProcessEpoch: "epoch", AttemptId: "attempt", RunId: "run", FencingToken: []byte{0, 1}}
}

func (*server) RenewLease(_ context.Context, r *pb.RenewLeaseRequest) (*pb.RenewLeaseResponse, error) {
	l := r.GetLease()
	if l.GetInvokerId() != "spike" || l.GetProcessEpoch() != "epoch" || l.GetAttemptId() != "attempt" || l.GetRunId() != "run" || string(l.GetFencingToken()) != "\x00\x01" {
		return nil, status.Error(codes.FailedPrecondition, "lease mismatch")
	}
	return &pb.RenewLeaseResponse{LeaseExpiresUnix: 1800000030}, nil
}

func (*server) WatchCommands(r *pb.WatchCommandsRequest, stream pb.LeaseFixture_WatchCommandsServer) error {
	if r.InvokerId != "spike" || r.ProcessEpoch != "epoch" {
		return status.Error(codes.InvalidArgument, "unexpected watcher")
	}
	return stream.Send(&pb.Command{CommandId: "cancel-1", Payload: &pb.Command_CancelRun{CancelRun: &pb.CancelRun{Lease: fixtureLease(), Reason: "fixture"}}})
}

func (*server) Heartbeat(_ context.Context, r *pb.HeartbeatRequest) (*pb.Acknowledgement, error) {
	if r.InvokerId != "spike" || r.ProtocolVersion != 1 || len(r.ExecutionFormats) != 2 || r.ExecutionFormats[0] != "standard" || r.ExecutionFormats[1] != "scripted_lua" || r.Capacity != 4 || r.Load != 2 {
		return nil, status.Error(codes.InvalidArgument, "unexpected heartbeat")
	}
	return &pb.Acknowledgement{Duplicate: true}, nil
}

func (*server) Claim(ctx context.Context, r *pb.ClaimRequest) (*pb.ClaimResponse, error) {
	if r.RunId == "wait-for-deadline" {
		<-ctx.Done()
		return nil, status.FromContextError(ctx.Err()).Err()
	}
	if r.InvokerId != "spike" || r.AttemptId != "attempt" || r.RunId != "run" {
		return nil, status.Error(codes.InvalidArgument, "unexpected claim")
	}
	return &pb.ClaimResponse{LeaseExpiresUnix: 1800000000, SourceUrl: "https://invalid.example/source", BundleUrl: "https://invalid.example/bundle"}, nil
}

func (s *server) Report(_ context.Context, r *pb.Event) (*pb.Acknowledgement, error) {
	if len(r.EventId) != 16 || r.EventId[6]>>4 != 4 || r.EventId[8]>>6 != 2 || r.AttemptId != "attempt" || r.RunId != "run" || r.SubmissionId != "submission" || r.InvokerId != "spike" || r.Sequence != 1 || r.SchemaVersion != 1 || r.OccurredAtUnixMillis != 1800000000000 || r.Kind != pb.Event_TEST_FINISHED || r.Verdict != "OK" || r.Score == nil || *r.Score != "1.125" || r.TestId != "test" || r.SubgroupId != "subgroup" || r.ArtifactId != "artifact" {
		return nil, status.Error(codes.InvalidArgument, "unexpected event")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case s.lastEvent == nil:
		s.lastEvent = proto.Clone(r).(*pb.Event)
		// Model an accepted event whose response did not reach the caller.
		return nil, status.Error(codes.Unavailable, "simulated lost acknowledgement")
	case !s.replayed && proto.Equal(s.lastEvent, r):
		s.replayed = true
		return &pb.Acknowledgement{Duplicate: true}, nil
	default:
		return nil, status.Error(codes.FailedPrecondition, "unexpected extra Report")
	}
}

func main() {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	s := grpc.NewServer()
	fixture := &server{}
	pb.RegisterControlServer(s, fixture)
	pb.RegisterLeaseFixtureServer(s, fixture)
	if err := os.WriteFile(os.Args[1], []byte(l.Addr().String()+"\n"), 0600); err != nil {
		log.Fatal(err)
	}
	log.Fatal(s.Serve(l))
}
