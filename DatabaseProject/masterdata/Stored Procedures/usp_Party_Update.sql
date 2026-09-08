
CREATE   PROCEDURE masterdata.usp_Party_Update
    @Id                 INT,
    @PartyCode          NVARCHAR(20),
    @PartyName          NVARCHAR(200),
    @IsSupplier         BIT = 0,
    @IsClient           BIT = 0,
    @IsSalesman         BIT = 0,
    @IsEmployee         BIT = 0,
    @BranchId           INT            = NULL,
    @ContactPerson      NVARCHAR(150)  = NULL,
    @Phone              NVARCHAR(50)   = NULL,
    @Mobile             NVARCHAR(50)   = NULL,
    @Email              NVARCHAR(150)  = NULL,
    @Address            NVARCHAR(500)  = NULL,
    @Country            NVARCHAR(2)    = NULL,
    @TaxRegistrationNo  NVARCHAR(50)   = NULL,
    @Notes              NVARCHAR(1000) = NULL,
    @UserId             INT            = NULL,
    @DefaultPriceListId INT            = NULL,
    @DefaultCurrencyId  INT            = NULL,
    @IsActive           BIT            = 1,
    @RowVersion         BINARY(8)      = NULL,
    @ActorUserId        INT            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @PartyCode = LTRIM(RTRIM(@PartyCode));  SET @PartyName = LTRIM(RTRIM(@PartyName));
    SET @ContactPerson = NULLIF(LTRIM(RTRIM(@ContactPerson)), N'');
    SET @Phone   = NULLIF(LTRIM(RTRIM(@Phone)), N'');   SET @Mobile = NULLIF(LTRIM(RTRIM(@Mobile)), N'');
    SET @Email   = NULLIF(LTRIM(RTRIM(@Email)), N'');   SET @Address = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @Country = NULLIF(UPPER(LTRIM(RTRIM(@Country))), N'');
    SET @TaxRegistrationNo = NULLIF(LTRIM(RTRIM(@TaxRegistrationNo)), N'');
    SET @Notes   = NULLIF(LTRIM(RTRIM(@Notes)), N'');
    SET @IsSupplier = ISNULL(@IsSupplier, 0); SET @IsClient = ISNULL(@IsClient, 0);
    SET @IsSalesman = ISNULL(@IsSalesman, 0); SET @IsEmployee = ISNULL(@IsEmployee, 0);
    SET @IsActive = ISNULL(@IsActive, 1);

    DECLARE @WasSupplier BIT, @WasClient BIT, @WasSalesman BIT, @WasEmployee BIT;
    SELECT @WasSupplier = IsSupplier, @WasClient = IsClient, @WasSalesman = IsSalesman, @WasEmployee = IsEmployee
    FROM masterdata.Parties WHERE Id = @Id;
    IF @WasSupplier IS NULL
        THROW 60006, 'Party not found.', 1;

    EXEC masterdata.usp_Party_Validate @Id, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @DefaultPriceListId, @DefaultCurrencyId;

    -- A type cannot be removed while the party is referenced in that role.
    DECLARE @Ref BIT;
    IF @WasSupplier = 1 AND @IsSupplier = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Supplier', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Supplier type cannot be removed: this party is used as a supplier in existing transactions.', 1;
    END
    IF @WasClient = 1 AND @IsClient = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Client', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Client type cannot be removed: this party is used as a client in existing transactions.', 1;
    END
    IF @WasSalesman = 1 AND @IsSalesman = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Salesman', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Salesman type cannot be removed: this party is used as a salesman in existing transactions.', 1;
    END
    IF @WasEmployee = 1 AND @IsEmployee = 0
    BEGIN
        EXEC masterdata.usp_Party_IsReferencedAs @Id, N'Employee', @Ref OUTPUT;
        IF @Ref = 1 THROW 60005, 'The Employee type cannot be removed: this party is used as an employee in existing transactions.', 1;
    END

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 60004, 'This party was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.Parties
    SET PartyCode = @PartyCode, PartyName = @PartyName,
        IsSupplier = @IsSupplier, IsClient = @IsClient, IsSalesman = @IsSalesman, IsEmployee = @IsEmployee,
        BranchId = @BranchId, ContactPerson = @ContactPerson, Phone = @Phone, Mobile = @Mobile, Email = @Email,
        Address = @Address, Country = @Country, TaxRegistrationNo = @TaxRegistrationNo, Notes = @Notes,
        UserId = @UserId, DefaultPriceListId = @DefaultPriceListId, DefaultCurrencyId = @DefaultCurrencyId,
        IsActive = @IsActive, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @ActorUserId
    WHERE Id = @Id;
END