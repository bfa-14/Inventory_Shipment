/* -- reading a setting from inside other procedures --------------------------------------------- */

CREATE   FUNCTION configuration.fn_SettingValue (@SettingKey NVARCHAR(100))
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN (SELECT ISNULL(v.Value, d.DefaultValue)
            FROM configuration.SettingDefinitions d
            LEFT JOIN configuration.SettingValues v ON v.SettingKey = d.SettingKey
            WHERE d.SettingKey = @SettingKey);
END

GO

