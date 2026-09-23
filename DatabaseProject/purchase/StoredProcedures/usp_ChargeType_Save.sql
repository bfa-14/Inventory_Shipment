CREATE   PROCEDURE purchase.usp_ChargeType_Save
    @Id                  INT           = NULL,
    @ChargeCode          NVARCHAR(10),
    @ChargeName          NVARCHAR(100),
    @AllocationMethod    NVARCHAR(10),
    @IncludeInLandedCost BIT           = 1,
    @IsRecoverableTax    BIT           = 0,
    @Description         NVARCHAR(500) = NULL,
    @IsActive            BIT           = 1,
    @RowVersion          BINARY(8)     = NULL,
    @UserId              INT           = NULL,
    @NewId               INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @ChargeCode = UPPER(NULLIF(LTRIM(RTRIM(@ChargeCode)), N''));
    SET @ChargeName = NULLIF(LTRIM(RTRIM(@ChargeName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @ChargeCode IS NULL THROW 68000, 'Charge Code is required.', 1;
    IF @ChargeName IS NULL THROW 68000, 'Charge Name is required.', 1;
    IF @AllocationMethod NOT IN (N'Value', N'Quantity', N'Weight', N'Volume', N'Manual') THROW 68000, 'Allocation method must be Value, Quantity, Weight, Volume or Manual.', 1;
    IF ISNULL(@IsRecoverableTax, 0) = 1 AND ISNULL(@IncludeInLandedCost, 1) = 1 THROW 68000, 'A recoverable tax cannot be included in the landed cost.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeCode = @ChargeCode AND (@Id IS NULL OR Id <> @Id)) THROW 68001, 'This Charge Code already exists.', 1;
    IF EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE ChargeName = @ChargeName AND (@Id IS NULL OR Id <> @Id)) THROW 68002, 'This Charge Name already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO purchase.ChargeTypes (ChargeCode, ChargeName, AllocationMethod, IncludeInLandedCost, IsRecoverableTax, Description, IsActive, CreatedBy)
        VALUES (@ChargeCode, @ChargeName, @AllocationMethod, ISNULL(@IncludeInLandedCost, 1), ISNULL(@IsRecoverableTax, 0), @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id) THROW 68006, 'Charge type not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 68004, 'This charge type was modified by another user. Reload the page and try again.', 1;
        UPDATE purchase.ChargeTypes
        SET ChargeCode = @ChargeCode, ChargeName = @ChargeName, AllocationMethod = @AllocationMethod, IncludeInLandedCost = ISNULL(@IncludeInLandedCost, 1),
            IsRecoverableTax = ISNULL(@IsRecoverableTax, 0), Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END

GO

