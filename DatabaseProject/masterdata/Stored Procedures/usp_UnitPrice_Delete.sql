CREATE   PROCEDURE masterdata.usp_UnitPrice_Delete
    @Id     INT,
    @UserId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Price DECIMAL(18,4) = (SELECT Price FROM masterdata.UnitPrices WHERE Id = @Id);
    IF @Price IS NULL
        THROW 59006, 'Unit price not found.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;
        EXEC masterdata.usp_UnitPrice_LogHistory @UnitPriceId = @Id, @ChangeType = 5, @OldPrice = @Price, @NewPrice = NULL, @UserId = @UserId;
        DELETE FROM masterdata.UnitPrices WHERE Id = @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END