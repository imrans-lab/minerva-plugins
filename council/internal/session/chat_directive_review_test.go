package session

import (
	"reflect"
	"testing"
	"time"
)

func TestIncompleteAndWhitespaceDirectivesNeverOpenConsultations(t *testing.T) {
	for _, line := range []string{
		"/ask", "/ask\tNobody why?", "/ask\nNobody why?", "/ask\u00a0Nobody why?",
		"/bench", "/bench\twhy?", "/bench\nwhy?", "/bench\u00a0why?",
		"/council", "/council\tmissing", "/council-session", "/council-session\nmissing",
	} {
		t.Run(line, func(t *testing.T) {
			s := reviewStore(t)
			before := s.Export()
			result := s.ChatTurnFor(ChatTurn{ChatID: "chat-directive-review", Text: line}, time.Second)
			if result.Reply.Kind != ChatError || !reflect.DeepEqual(before, s.Export()) {
				t.Fatalf("directive fell through to a consultation: %+v", result)
			}
		})
	}
}
