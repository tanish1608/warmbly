package jobs

import (
	"context"

	"github.com/google/uuid"
	"github.com/rs/zerolog/log"
	"github.com/warmbly/warmbly/internal/models"
)

func (s *JobsService) HandleHistoryIDUpdate(ctx context.Context, e *models.JobEventHistoryIDUpdate) error {
	// Drop a malformed event instead of returning an error. A missing id can only
	// ever fail its foreign key, so retrying is futile, and the bus redelivers a
	// failed event indefinitely: one bad payload otherwise stalls the whole
	// subject and no mail is ingested at all.
	if e.UserID == uuid.Nil || e.EmailID == uuid.Nil {
		log.Error().
			Str("user_id", e.UserID.String()).
			Str("email_id", e.EmailID.String()).
			Msg("history id update missing user or email id; dropping event")
		return nil
	}

	if err := s.EmailHistoryIDRepository.Put(ctx, e.UserID, e.EmailID, e.HistoryID); err != nil {
		CaptureError(e.UserID, e.EmailID, err)
		return err
	}

	return nil
}
