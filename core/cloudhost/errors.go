package cloudhost

import "errors"

// Error is shown to the user as is. Messages never contain credentials or
// raw command output, which may echo secrets.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
	English string `json:"message_en"`
}

func (e *Error) Error() string { return e.Message }

func newError(code, message, english string) *Error {
	return &Error{Code: code, Message: message, English: english}
}

// AsError returns the user-facing error, wrapping anything unexpected generically.
func AsError(err error) *Error {
	if err == nil {
		return nil
	}
	var known *Error
	if errors.As(err, &known) {
		return known
	}
	if errors.Is(err, errCancelled) {
		return newError("cancelled", "已取消", "Cancelled")
	}
	return newError("unexpected", "操作没有完成", "The operation did not complete")
}

var errCancelled = errors.New("cancelled")
