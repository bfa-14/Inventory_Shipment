CREATE   PROCEDURE masterdata.usp_Party_Validate
    @Id                 INT = NULL,       -- NULL when creating
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT, @IsClient BIT, @IsSalesman BIT, @IsEmployee BIT,
    @BranchId           INT,
    @Email              NVARCHAR(150),
    @UserId             INT,
    @DefaultPriceListId INT,
    @DefaultCurrencyId  INT
AS
BEGIN
    SET NOCOUNT ON;

    IF @PartyCode IS NULL OR @PartyCode = N'' THROW 60000, 'Party Code is required.', 1;
    IF @PartyName IS NULL OR @PartyName = N'' THROW 60000, 'Party Name is required.', 1;
    IF ISNULL(@IsSupplier, 0) = 0 AND ISNULL(@IsClient, 0) = 0 AND ISNULL(@IsSalesman, 0) = 0 AND ISNULL(@IsEmployee, 0) = 0
        THROW 60000, 'At least one Party Type must be selected.', 1;
    IF @Email IS NOT NULL AND (@Email NOT LIKE N'%_@_%.__%' OR @Email LIKE N'% %')
        THROW 60000, 'Email address format is not valid.', 1;

    IF @BranchId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @BranchId AND IsActive = 1)
        THROW 60008, 'Branch not found or inactive.', 1;
    IF @DefaultPriceListId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PriceLists WHERE Id = @DefaultPriceListId AND IsActive = 1)
        THROW 60008, 'Default price list not found or inactive.', 1;
    IF @DefaultCurrencyId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Currencies WHERE Id = @DefaultCurrencyId AND IsActive = 1)
        THROW 60008, 'Default currency not found or inactive.', 1;
    IF @UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM security.Users WHERE Id = @UserId)
        THROW 60008, 'Linked user not found.', 1;
    IF @UserId IS NOT NULL AND EXISTS (SELECT 1 FROM masterdata.Parties WHERE UserId = @UserId AND (@Id IS NULL OR Id <> @Id))
        THROW 60002, 'This user is already linked to another party.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Parties WHERE PartyCode = @PartyCode AND (@Id IS NULL OR Id <> @Id))
        THROW 60001, 'A party with this Party Code already exists.', 1;
END