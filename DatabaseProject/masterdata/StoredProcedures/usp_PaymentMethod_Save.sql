CREATE   PROCEDURE masterdata.usp_PaymentMethod_Save
    @Id          INT           = NULL,
    @MethodCode  NVARCHAR(10),
    @MethodName  NVARCHAR(100),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @MethodCode = UPPER(NULLIF(LTRIM(RTRIM(@MethodCode)), N''));
    SET @MethodName = NULLIF(LTRIM(RTRIM(@MethodName)), N'');
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    IF @MethodCode IS NULL THROW 71000, 'Payment method code is required.', 1;
    IF @MethodName IS NULL THROW 71000, 'Payment method name is required.', 1;
    IF EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE MethodCode = @MethodCode AND (@Id IS NULL OR Id <> @Id))
        THROW 71013, 'This payment method code already exists.', 1;

    IF @Id IS NULL
    BEGIN
        INSERT INTO masterdata.PaymentMethods (MethodCode, MethodName, Description, IsActive, CreatedBy)
        VALUES (@MethodCode, @MethodName, @Description, ISNULL(@IsActive, 1), @UserId);
        SET @NewId = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id) THROW 71006, 'Payment method not found.', 1;
        IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @Id AND RowVersion = @RowVersion)
            THROW 71004, 'This payment method was modified by another user. Reload the page and try again.', 1;
        UPDATE masterdata.PaymentMethods
        SET MethodCode = @MethodCode, MethodName = @MethodName, Description = @Description, IsActive = ISNULL(@IsActive, 1),
            UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
        WHERE Id = @Id;
        SET @NewId = @Id;
    END
END

GO

