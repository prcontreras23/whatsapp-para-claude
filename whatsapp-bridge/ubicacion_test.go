package main

import (
	"testing"

	waProto "go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func TestUbicacion(t *testing.T) {
	m := &waProto.Message{LocationMessage: &waProto.LocationMessage{
		DegreesLatitude: proto.Float64(18.5292873), DegreesLongitude: proto.Float64(-69.9149628),
	}}
	if got, want := extractTextContent(m), "[ubicación] https://maps.google.com/?q=18.529287,-69.914963"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	m.LocationMessage.Name = proto.String("Iglesia Bethesda")
	if got := extractTextContent(m); got != "[ubicación] Iglesia Bethesda — https://maps.google.com/?q=18.529287,-69.914963" {
		t.Fatalf("got %q", got)
	}
}
