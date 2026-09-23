CREATE   PROCEDURE masterdata.usp_Party_Delete
    @Id INT
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id)
        THROW 60006, 'Party not found.', 1;

    DECLARE @Ref BIT;
    EXEC masterdata.usp_Party_IsReferencedAs @Id, NULL, @Ref OUTPUT;
    IF @Ref = 1
        THROW 60003, 'This party cannot be deleted because it is referenced by existing transactions. You may deactivate the party instead.', 1;

    DELETE FROM masterdata.Parties WHERE Id = @Id;
END

GO

