CREATE   FUNCTION configuration.fn_SettingBool (@SettingKey NVARCHAR(100))
RETURNS BIT
AS
BEGIN
    RETURN CASE WHEN LOWER(ISNULL(configuration.fn_SettingValue(@SettingKey), N'')) IN (N'true', N'1', N'yes') THEN 1 ELSE 0 END;
END

GO

