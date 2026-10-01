/* -- the view ----------------------------------------------------------------------------------- */

CREATE   PROCEDURE configuration.usp_Setting_List
    @OnlyPublic BIT = 0
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.SettingKey, d.GroupName, d.Label, d.Description, d.ValueType, d.DefaultValue, d.MinValue, d.MaxValue,
           d.IsPublic, d.SortOrder,
           Value     = ISNULL(v.Value, d.DefaultValue),
           IsDefault = CAST(CASE WHEN v.SettingKey IS NULL THEN 1 ELSE 0 END AS BIT),
           UpdatedAtUtc = v.UpdatedAtUtc,
           UpdatedByName = u.FullName
    FROM configuration.SettingDefinitions d
    LEFT JOIN configuration.SettingValues v ON v.SettingKey = d.SettingKey
    LEFT JOIN security.Users u ON u.Id = v.UpdatedBy
    WHERE @OnlyPublic = 0 OR d.IsPublic = 1
    ORDER BY d.GroupName, d.SortOrder, d.Label;
END

GO

