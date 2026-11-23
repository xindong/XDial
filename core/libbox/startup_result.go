package libbox

import "github.com/kafeifei/xdial/core/recovery"

// StartupResult preserves a typed recovery decision across gomobile's error bridge.
type StartupResult struct {
	Value     string
	Message   string
	Retryable bool
}

func startupResult(value string, err error) *StartupResult {
	r := &StartupResult{Value: value}
	if err != nil {
		r.Message = err.Error()
		r.Retryable = recovery.IsTransient(err)
	}
	return r
}

// The host can display Message without exposing the resolver name or resource URL.
type redactedFailure struct {
	message string
	cause   error
}

func (e redactedFailure) Error() string { return e.message }
func (e redactedFailure) Unwrap() error { return e.cause }

// GenerateNESessionResult preserves preparation failure classification for Apple hosts.
func GenerateNESessionResult(profileJSON, server, basePath string) *StartupResult {
	return startupResult(GenerateNESession(profileJSON, server, basePath))
}

func GenerateNEConfigResult(profileJSON, server, basePath string) *StartupResult {
	return startupResult(GenerateNEConfig(profileJSON, server, basePath))
}
