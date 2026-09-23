CREATE   PROCEDURE masterdata.usp_UnitPrice_SetActive
    @Id       INT,
    @IsActive BIT,
    @UserId   INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4), @OldActive BIT;
    SELECT @Price = Price, @OldActive = IsActive FROM masterdata.UnitPrices WHERE Id = @Id;
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;
    IF @OldActive = @IsActive
        RETURN;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE masterdata.UnitPrices SET IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId WHERE Id = @Id;

        DECLARE @StatusType TINYINT = CASE WHEN @IsActive = 1 THEN 3 ELSE 4 END;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = @StatusType, @OldPrice = @Price, @NewPrice = @Price, @UserId = @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

