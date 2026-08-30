using Inventory_Shipment.API.Authorization;
using Inventory_Shipment.API.Extensions;
using Inventory_Shipment.Model.DTOs.Users;
using Inventory_Shipment.Model.Security;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.AspNetCore.Mvc;

namespace Inventory_Shipment.API.Controllers;

/// <summary>User administration. Every action is guarded by a security.users.* permission.</summary>
[ApiController]
[Route("api/users")]
[Produces("application/json")]
public sealed class UsersController : ControllerBase
{
    private readonly IUserService _userService;

    public UsersController(IUserService userService)
    {
        _userService = userService;
    }

    [HttpGet]
    [HasPermission(Permissions.Security.UsersView)]
    [ProducesResponseType<IReadOnlyList<UserDto>>(StatusCodes.Status200OK)]
    public async Task<ActionResult<IReadOnlyList<UserDto>>> GetAll(CancellationToken cancellationToken)
    {
        var result = await _userService.GetAllAsync(cancellationToken);
        return result.ToActionResult(this);
    }

    [HttpGet("{id:int}")]
    [HasPermission(Permissions.Security.UsersView)]
    [ProducesResponseType<UserDto>(StatusCodes.Status200OK)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<UserDto>> GetById(int id, CancellationToken cancellationToken)
    {
        var result = await _userService.GetByIdAsync(id, cancellationToken);
        return result.ToActionResult(this);
    }

    /// <summary>Creates a user. The password must satisfy the configured password policy.</summary>
    [HttpPost]
    [HasPermission(Permissions.Security.UsersCreate)]
    [ProducesResponseType<UserDto>(StatusCodes.Status201Created)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult<UserDto>> Create([FromBody] CreateUserRequest request, CancellationToken cancellationToken)
    {
        var result = await _userService.CreateAsync(request, User.GetUserId(), cancellationToken);

        return result.IsSuccess
            ? CreatedAtAction(nameof(GetById), new { id = result.Value!.Id }, result.Value)
            : this.ToProblem(result);
    }

    /// <summary>Updates the user's profile (full name and e-mail).</summary>
    [HttpPut("{id:int}")]
    [HasPermission(Permissions.Security.UsersEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status409Conflict)]
    public async Task<ActionResult> Update(int id, [FromBody] UpdateUserRequest request, CancellationToken cancellationToken)
    {
        var result = await _userService.UpdateAsync(id, request, cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Activates or deactivates a user. Deactivating revokes the user's sessions.</summary>
    [HttpPatch("{id:int}/status")]
    [HasPermission(Permissions.Security.UsersEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> SetStatus(int id, [FromBody] SetUserStatusRequest request, CancellationToken cancellationToken)
    {
        var result = await _userService.SetActiveAsync(id, request.IsActive, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Sets a new password for a user and revokes the user's sessions.</summary>
    [HttpPost("{id:int}/reset-password")]
    [HasPermission(Permissions.Security.UsersEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> ResetPassword(int id, [FromBody] ResetPasswordRequest request, CancellationToken cancellationToken)
    {
        var result = await _userService.ResetPasswordAsync(id, request.NewPassword, cancellationToken);
        return result.ToNoContentResult(this);
    }

    /// <summary>Replaces the complete set of roles the user holds.</summary>
    [HttpPut("{id:int}/roles")]
    [HasPermission(Permissions.Security.UsersEdit)]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status400BadRequest)]
    [ProducesResponseType<ProblemDetails>(StatusCodes.Status404NotFound)]
    public async Task<ActionResult> SetRoles(int id, [FromBody] SetUserRolesRequest request, CancellationToken cancellationToken)
    {
        var result = await _userService.SetRolesAsync(id, request.RoleIds, User.GetUserId(), cancellationToken);
        return result.ToNoContentResult(this);
    }
}
