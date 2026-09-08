
CREATE   PROCEDURE masterdata.usp_Party_Create
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
    @ActorUserId        INT            = NULL,   -- who is saving (CreatedBy)
    @NewId              INT OUTPUT
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

    EXEC masterdata.usp_Party_Validate NULL, @PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee,
         @BranchId, @Email, @UserId, @DefaultPriceListId, @DefaultCurrencyId;

    INSERT INTO masterdata.Parties (PartyCode, PartyName, IsSupplier, IsClient, IsSalesman, IsEmployee, BranchId,
                                    ContactPerson, Phone, Mobile, Email, Address, Country, TaxRegistrationNo, Notes,
                                    UserId, DefaultPriceListId, DefaultCurrencyId, IsActive, CreatedBy)
    VALUES (@PartyCode, @PartyName, @IsSupplier, @IsClient, @IsSalesman, @IsEmployee, @BranchId,
            @ContactPerson, @Phone, @Mobile, @Email, @Address, @Country, @TaxRegistrationNo, @Notes,
            @UserId, @DefaultPriceListId, @DefaultCurrencyId, @IsActive, @ActorUserId);

    SET @NewId = SCOPE_IDENTITY();
END