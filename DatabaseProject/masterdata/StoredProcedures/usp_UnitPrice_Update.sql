CREATE   PROCEDURE masterdata.usp_UnitPrice_Update
    @Id         INT,
    @Price      DECIMAL(18,4),
    @IsActive   BIT       = NULL,   -- NULL = leave unchanged
    @RowVersion BINARY(8) = NULL,
    @UserId     INT       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @OldPrice DECIMAL(18,4), @OldActive BIT;
    SELECT @OldPrice = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;

    IF @OldPrice IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @Price IS NULL THROW 59000, 'Price is required.', 1;
    IF @Price < 0 THROW 59000, 'Price cannot be negative.', 1;
    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.UnitPrices WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 59004, 'This price was modified by another user. Reload the page and try again.', 1;

    SET @IsActive = ISNULL(@IsActive, @OldActive);

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices
        SET Price = @Price, IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;

        IF @Price <> @OldPrice
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 2, @OldPrice = @OldPrice, @NewPrice = @Price, @UserId = @UserId;

        IF @IsActive <> @OldActive
        BEGIN
            DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
            EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

