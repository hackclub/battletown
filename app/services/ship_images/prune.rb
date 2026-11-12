module ShipImages
  # Housekeeping for ship screenshots (rake ship_images:prune; flag `ship_screenshots`, a no-op while it is off):
  #   - removes the screenshots of a ship that was withdrawn more than `withdrawn_retention_days` ago (a withdrawn ship is
  #     final, so its last update is when it was withdrawn);
  #   - safety checks that should never find anything, because the database enforces them: rows whose ship is gone, rows whose
  #     owner is not the ship's owner. Anything found is deleted (a picture that cannot be tied to its owner could not be
  #     erased with them) and counted, so a non-zero count is worth a look.
  # Returns counts only; no ids, no names. Safe to repeat.
  module Prune
    Result = Data.define(:skipped, :withdrawn, :orphaned, :mismatched)

    module_function

    def call(now: Time.current, config: Config.current)
      return Result.new(skipped: true, withdrawn: 0, orphaned: 0, mismatched: 0) unless Features.enabled?(:ship_screenshots)

      cutoff = now - config.withdrawn_retention_days.days
      expired = Ship.where(status: "withdrawn").where(updated_at: ...cutoff).select(:id)
      withdrawn = ShipImage.where(ship_id: expired).delete_all
      orphaned = ShipImage.where.not(ship_id: Ship.select(:id)).or(ShipImage.where.not(user_id: User.select(:id))).delete_all
      mismatched = ShipImage.where(id: ShipImage.joins(:ship).where("ship_images.user_id <> ships.user_id").select(:id)).delete_all
      Result.new(skipped: false, withdrawn: withdrawn, orphaned: orphaned, mismatched: mismatched)
    end
  end
end
