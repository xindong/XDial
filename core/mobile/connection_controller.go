package mobile

import "github.com/kafeifei/xdial/core/recovery"

// ConnectionController is retained for callers of the original mobile API.
type ConnectionController = recovery.ConnectionController

func NewConnectionController() *ConnectionController {
	return recovery.NewConnectionController()
}
