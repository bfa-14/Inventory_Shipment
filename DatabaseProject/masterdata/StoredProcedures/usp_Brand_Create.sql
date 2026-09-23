CREATE   PROCEDURE masterdata.usp_Brand_Create
    @BrandCode   NVARCHAR(20),
    @BrandName   NVARCHAR(150),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @UserId      INT           = NULL,
    @NewId       INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @BrandCode   = LTRIM(RTRIM(@BrandCode));
    SET @BrandName   = LTRIM(RTRIM(@BrandName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF @BrandCode IS NULL OR @BrandCode = N''
        THROW 55000, 'Brand Code is required.', 1;

    IF @BrandName IS NULL OR @BrandName = N''
        THROW 55000, 'Brand Name is required.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Brands WHERE BrandCode = @BrandCode)
        THROW 55001, 'A brand with this Brand Code already exists.', 1;

    INSERT INTO masterdata.Brands (BrandCode, BrandName, Description, IsActive, CreatedBy)
    VALUES (@BrandCode, @BrandName, @Description, @IsActive, @UserId);

    SET @NewId = SCOPE_IDENTITY();
END

GO

