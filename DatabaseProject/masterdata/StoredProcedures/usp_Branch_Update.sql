CREATE   PROCEDURE masterdata.usp_Branch_Update
    @Id                INT,
    @BranchCode        NVARCHAR(20),
    @BranchName        NVARCHAR(150),
    @Address           NVARCHAR(500) = NULL,
    @IsMainBranch      BIT           = 0,
    @IsActive          BIT           = 1,
    @ReplaceMainBranch BIT           = 0,
    @RowVersion        BINARY(8)     = NULL,   -- pass the value read earlier; NULL skips the concurrency check
    @UserId            INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BranchCode = LTRIM(RTRIM(@BranchCode));
    SET @BranchName = LTRIM(RTRIM(@BranchName));
    SET @Address    = NULLIF(LTRIM(RTRIM(@Address)), N'');
    SET @IsMainBranch = ISNULL(@IsMainBranch, 0);
    SET @IsActive     = ISNULL(@IsActive, 1);

    IF NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id)
        THROW 51006, 'Branch not found.', 1;

    IF @BranchCode IS NULL OR @BranchCode = N''
        THROW 51000, 'Branch Code is required.', 1;

    IF @BranchName IS NULL OR @BranchName = N''
        THROW 51000, 'Branch Name is required.', 1;

    IF @IsMainBranch = 1 AND @IsActive = 0
        THROW 51005, 'The Main Branch must be active.', 1;

    IF EXISTS (SELECT 1 FROM masterdata.Branches WHERE BranchCode = @BranchCode AND Id <> @Id)
        THROW 51001, 'A branch with this Branch Code already exists.', 1;

    IF @RowVersion IS NOT NULL AND NOT EXISTS (SELECT 1 FROM masterdata.Branches WHERE Id = @Id AND RowVersion = @RowVersion)
        THROW 51004, 'This branch was modified by another user. Reload the page and try again.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @IsMainBranch = 1
        BEGIN
            DECLARE @CurrentMainId INT =
                (SELECT TOP (1) Id FROM masterdata.Branches WITH (UPDLOCK, HOLDLOCK)
                 WHERE IsMainBranch = 1 AND IsActive = 1 AND Id <> @Id);

            IF @CurrentMainId IS NOT NULL
            BEGIN
                IF @ReplaceMainBranch = 0
                    THROW 51002, 'Another active branch is already designated as the Main Branch. Confirm to replace it.', 1;

                UPDATE masterdata.Branches
                SET IsMainBranch = 0, UpdatedAtUtc = SYSUTCDATETIME(), UpdatedBy = @UserId
                WHERE Id = @CurrentMainId;
            END
        END

        UPDATE masterdata.Branches
        SET BranchCode   = @BranchCode,
            BranchName   = @BranchName,
            Address      = @Address,
            IsMainBranch = @IsMainBranch,
            IsActive     = @IsActive,
            UpdatedAtUtc = SYSUTCDATETIME(),
            UpdatedBy    = @UserId
        WHERE Id = @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END

GO

