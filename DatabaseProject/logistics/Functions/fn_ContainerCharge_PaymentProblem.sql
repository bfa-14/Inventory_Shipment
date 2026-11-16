/* ================================================================== 2. What a cash charge needs */

CREATE   FUNCTION logistics.fn_ContainerCharge_PaymentProblem
(
    @PaymentType     TINYINT,
    @MethodId        INT,
    @AccountId       INT,
    @CurrencyId      INT,
    @ProviderPartyId INT,
    @ChargeTypeId    INT
)
RETURNS TABLE
AS
RETURN
(
    SELECT Message =
        CASE WHEN ISNULL(@PaymentType, 2) NOT IN (1, 2) THEN N'Payment Type must be Cash or On account.'
             WHEN ISNULL(@PaymentType, 2) = 2 THEN NULL
             WHEN EXISTS (SELECT 1 FROM purchase.ChargeTypes WHERE Id = @ChargeTypeId AND IsDeduction = 1)
                  THEN N'A deduction is not paid: choose On account.'
             WHEN @ProviderPartyId IS NULL THEN N'A cash charge is paid to its provider: choose the provider.'
             WHEN NOT EXISTS (SELECT 1 FROM masterdata.Parties WHERE Id = @ProviderPartyId AND IsActive = 1 AND IsSupplier = 1)
                  THEN N'The provider is not an active supplier, so it cannot be paid: choose On account.'
             WHEN @MethodId IS NULL THEN N'A cash charge needs its Payment Method.'
             WHEN NOT EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND IsActive = 1)
                  THEN N'The payment method is no longer active.'
             WHEN EXISTS (SELECT 1 FROM masterdata.PaymentMethods WHERE Id = @MethodId AND MethodCode = N'CHQ')
                  THEN N'A cheque is paid with Purchase > Supplier Payments, where its details are typed: choose On account.'
             WHEN @AccountId IS NULL THEN N'A cash charge needs the Cash / Bank Account it was paid from.'
             ELSE (SELECT CASE WHEN a.IsActive = 0 THEN N'The account ' + a.AccountCode + N' is no longer active.'
                               WHEN a.CurrencyId <> @CurrencyId THEN N'The account ' + a.AccountCode + N' holds ' + ac.CurrencyCode
                                    + N', but this charge is in ' + ISNULL(cc.CurrencyCode, N'another currency') + N'. Choose an account in '
                                    + ISNULL(cc.CurrencyCode, N'the charge''s currency') + N'.' END
                   FROM (SELECT 1 AS One) one
                   LEFT JOIN masterdata.CashBankAccounts a ON a.Id = @AccountId
                   LEFT JOIN masterdata.Currencies ac      ON ac.Id = a.CurrencyId
                   LEFT JOIN masterdata.Currencies cc      ON cc.Id = @CurrencyId)
        END
);