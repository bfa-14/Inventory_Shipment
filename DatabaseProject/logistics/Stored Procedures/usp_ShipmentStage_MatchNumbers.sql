-- box of "MRSU8190808 , CAAU9368456" too) or by ref, spaces, dashes, dots and slashes ignored; an open container
-- before a received or cancelled one. Matches > 1 among the open ones: found twice, none chosen.
CREATE   PROCEDURE logistics.usp_ShipmentStage_MatchNumbers
    @Numbers logistics.tvp_TextList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Rows TABLE (RowNo INT NOT NULL PRIMARY KEY, InputNumber NVARCHAR(100) NULL, NumberKey NVARCHAR(100) NOT NULL);
    INSERT INTO @Rows (RowNo, InputNumber, NumberKey)
    SELECT n.RowNo, LTRIM(RTRIM(n.Value)), k.NumberKey
    FROM @Numbers n
    CROSS APPLY logistics.fn_ContainerNumberKey(n.Value) k;

    DECLARE @Hits TABLE (RowNo INT NOT NULL, ContainerId INT NOT NULL, Rank TINYINT NOT NULL, PRIMARY KEY (RowNo, ContainerId));
    INSERT INTO @Hits (RowNo, ContainerId, Rank)
    SELECT DISTINCT r.RowNo, c.Id, CASE WHEN c.Status < 6 THEN 1 WHEN c.Status IN (6, 7) THEN 2 ELSE 3 END
    FROM @Rows r
    INNER JOIN (SELECT c.Id, c.Status, k.NumberKey
                FROM logistics.Containers c
                CROSS APPLY (SELECT c.ContainerRef AS V UNION ALL SELECT c.ContainerNo
                             UNION ALL SELECT LTRIM(RTRIM(b.value)) FROM STRING_SPLIT(c.ContainerNo, N',') b
                             WHERE c.ContainerNo LIKE N'%,%') v
                CROSS APPLY logistics.fn_ContainerNumberKey(v.V) k
                WHERE k.NumberKey <> N'') c ON c.NumberKey = r.NumberKey
    WHERE r.NumberKey <> N'';

    SELECT r.RowNo, r.InputNumber,
           ContainerId = CASE WHEN b.Cnt = 1 THEN b.ContainerId END,
           ContainerRef = CASE WHEN b.Cnt = 1 THEN c.ContainerRef END,
           ContainerNo = CASE WHEN b.Cnt = 1 THEN c.ContainerNo END,
           Matches = ISNULL(b.Cnt, 0)
    FROM @Rows r
    OUTER APPLY (SELECT Cnt = COUNT(*), ContainerId = MIN(h.ContainerId)
                 FROM @Hits h
                 WHERE h.RowNo = r.RowNo AND h.Rank = (SELECT MIN(h2.Rank) FROM @Hits h2 WHERE h2.RowNo = r.RowNo)) b
    LEFT JOIN logistics.Containers c ON c.Id = b.ContainerId AND b.Cnt = 1
    ORDER BY r.RowNo;
END