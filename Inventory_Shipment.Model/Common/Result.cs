namespace Inventory_Shipment.Model.Common;

public enum ErrorType
{
    None = 0,
    Validation,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    Locked
}

/// <summary>
/// Outcome of a service operation. Services never throw for expected failures
/// (wrong password, locked account, duplicate username...); they return a failed Result
/// that the API layer maps to the right HTTP status code.
/// </summary>
public class Result
{
    protected Result(bool isSuccess, ErrorType errorType, string? error, IReadOnlyList<string>? errors)
    {
        IsSuccess = isSuccess;
        ErrorType = errorType;
        Error = error;
        Errors = errors ?? [];
    }

    public bool IsSuccess { get; }
    public bool IsFailure => !IsSuccess;
    public ErrorType ErrorType { get; }
    public string? Error { get; }
    public IReadOnlyList<string> Errors { get; }

    public static Result Success() => new(true, ErrorType.None, null, null);

    public static Result Failure(ErrorType errorType, string error, IReadOnlyList<string>? errors = null)
        => new(false, errorType, error, errors);
}

public sealed class Result<T> : Result
{
    private Result(bool isSuccess, T? value, ErrorType errorType, string? error, IReadOnlyList<string>? errors)
        : base(isSuccess, errorType, error, errors)
    {
        Value = value;
    }

    public T? Value { get; }

    public static Result<T> Success(T value) => new(true, value, ErrorType.None, null, null);

    public static new Result<T> Failure(ErrorType errorType, string error, IReadOnlyList<string>? errors = null)
        => new(false, default, errorType, error, errors);
}
