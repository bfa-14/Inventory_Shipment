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
<<<<<<< HEAD
    protected Result(
        bool isSuccess,
        ErrorType errorType,
        string? error,
        IReadOnlyList<string>? errors,
        string? code = null,
        object? data = null)
=======
    protected Result(bool isSuccess, ErrorType errorType, string? error, IReadOnlyList<string>? errors)
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
    {
        IsSuccess = isSuccess;
        ErrorType = errorType;
        Error = error;
        Errors = errors ?? [];
<<<<<<< HEAD
        Code = code;
        Data = data;
=======
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
    }

    public bool IsSuccess { get; }
    public bool IsFailure => !IsSuccess;
    public ErrorType ErrorType { get; }
    public string? Error { get; }
    public IReadOnlyList<string> Errors { get; }

<<<<<<< HEAD
    /// <summary>
    /// Machine-readable reason for the failure, e.g. "DUPLICATE_CODE". The API surfaces it as the
    /// "code" extension of the problem details so the client can react without parsing the message.
    /// </summary>
    public string? Code { get; }

    /// <summary>
    /// Extra payload for the client, serialized into the "data" extension of the problem details
    /// (e.g. the branch that currently holds the Main Branch flag).
    /// </summary>
    public object? Data { get; }

=======
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
    public static Result Success() => new(true, ErrorType.None, null, null);

    public static Result Failure(ErrorType errorType, string error, IReadOnlyList<string>? errors = null)
        => new(false, errorType, error, errors);
<<<<<<< HEAD

    public static Result Failure(ErrorType errorType, string error, string code, object? data = null)
        => new(false, errorType, error, null, code, data);
=======
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
}

public sealed class Result<T> : Result
{
<<<<<<< HEAD
    private Result(
        bool isSuccess,
        T? value,
        ErrorType errorType,
        string? error,
        IReadOnlyList<string>? errors,
        string? code = null,
        object? data = null)
        : base(isSuccess, errorType, error, errors, code, data)
=======
    private Result(bool isSuccess, T? value, ErrorType errorType, string? error, IReadOnlyList<string>? errors)
        : base(isSuccess, errorType, error, errors)
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
    {
        Value = value;
    }

    public T? Value { get; }

    public static Result<T> Success(T value) => new(true, value, ErrorType.None, null, null);

    public static new Result<T> Failure(ErrorType errorType, string error, IReadOnlyList<string>? errors = null)
        => new(false, default, errorType, error, errors);
<<<<<<< HEAD

    public static new Result<T> Failure(ErrorType errorType, string error, string code, object? data = null)
        => new(false, default, errorType, error, null, code, data);
=======
>>>>>>> b5d1b30fa9d8e07e232f3ce84e9d4b71191cf21a
}
