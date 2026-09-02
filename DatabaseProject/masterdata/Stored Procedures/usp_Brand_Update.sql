CREATE   PROCEDURE masterdata.usp_Brand_Update
    @Id          INT,
    @BrandCode   NVARCHAR(20),
    @BrandName   NVARCHAR(150),
    @Description NVARCHAR(500) = NULL,
    @IsActive    BIT           = 1,
    @RowVersion  BINARY(8)     = NULL,
    @UserId      INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SET @BrandCode   = LTRIM(RTRIM(@BrandCode));
    SET @BrandName   = LTRIM(RTRIM(@BrandName));
    SET @Description = NULLIF(LTRIM(RTRIM(@Description)), N'');
    SET @IsActive    = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id)
        THROW 55006, 'Brand not found.', 1;

    IF @BrandCode IS NULL OR @BrandCode = N''
        THROW 55000, 'Brand Code is required.', 1;

    IF @BrandName IS NULL OR @BrandName = N''
        THROW 55000, 'Brand Name is required.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Brands WHERE BrandCode = @BrandCode AND Id <> @Id)
        THROW 55001, 'A brand with this Brand Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Brands WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 55004, 'This brand was modified by another user. Reload the page and try again.', 1;

    UPDATE masterdata.Brands
    SET BrandCode    = @BrandCode,
        BrandName    = @BrandName,
        Description  = @Description,
        IsActive     = @IsActive,
        UpdatedAtUtc = SYSUTCDATETIME(),
        UpdatedBy    = @UserId
    WHERE Id = @Id;
END