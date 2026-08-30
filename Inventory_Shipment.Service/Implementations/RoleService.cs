using Inventory_Shipment.Model.Common;
using Inventory_Shipment.Model.DTOs.Roles;
using Inventory_Shipment.Model.Entities;
using Inventory_Shipment.Repository.Database;
using Inventory_Shipment.Repository.Exceptions;
using Inventory_Shipment.Repository.Interfaces;
using Inventory_Shipment.Service.Interfaces;
using Microsoft.Extensions.Logging;

namespace Inventory_Shipment.Service.Implementations;

public sealed class RoleService : IRoleService
{
    private readonly IRoleRepository _roles;
    private readonly IPermissionRepository _permissions;
    private readonly ILogger<RoleService> _logger;

    public RoleService(IRoleRepository roles, IPermissionRepository permissions, ILogger<RoleService> logger)
    {
        _roles = roles;
        _permissions = permissions;
        _logger = logger;
    }

    public async Task<Result<IReadOnlyList<RoleDto>>> GetAllAsync(CancellationToken cancellationToken = default)
    {
        var roles = await _roles.GetAllAsync(cancellationToken);
        return Result<IReadOnlyList<RoleDto>>.Success(roles.Select(ToDto).ToList());
    }

    public async Task<Result<RoleDetailDto>> GetByIdAsync(int id, CancellationToken cancellationToken = default)
    {
        var role = await _roles.GetByIdAsync(id, cancellationToken);
        if (role is null)
        {
            return Result<RoleDetailDto>.Failure(ErrorType.NotFound, "Role not found.");
        }

        return Result<RoleDetailDto>.Success(await ToDetailDtoAsync(role, cancellationToken));
    }

    public async Task<Result<RoleDetailDto>> CreateAsync(CreateRoleRequest request, CancellationToken cancellationToken = default)
    {
        var name = request.Name.Trim();

        if (await _roles.NameExistsAsync(name, null, cancellationToken))
        {
            return Result<RoleDetailDto>.Failure(ErrorType.Conflict, "A role with that name already exists.");
        }

        var role = new Role
        {
            Name = name,
            Description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
            IsSystem = false,
            IsActive = true
        };

        try
        {
            await _roles.CreateAsync(role, cancellationToken);
        }
        catch (DuplicateRecordException)
        {
            return Result<RoleDetailDto>.Failure(ErrorType.Conflict, "A role with that name already exists.");
        }

        if (request.PermissionIds.Length > 0)
        {
            try
            {
                await _roles.SetPermissionsAsync(role.Id, request.PermissionIds, cancellationToken);
            }
            catch (SecurityRuleException ex)
            {
                return Result<RoleDetailDto>.Failure(MapRuleError(ex), ex.Message);
            }
        }

        _logger.LogInformation("Role {RoleId} ({Name}) created with {Count} permission(s)",
            role.Id, role.Name, request.PermissionIds.Length);

        var created = await _roles.GetByIdAsync(role.Id, cancellationToken);
        return created is null
            ? Result<RoleDetailDto>.Failure(ErrorType.NotFound, "Role not found.")
            : Result<RoleDetailDto>.Success(await ToDetailDtoAsync(created, cancellationToken));
    }

    public async Task<Result> UpdateAsync(int id, UpdateRoleRequest request, CancellationToken cancellationToken = default)
    {
        var existing = await _roles.GetByIdAsync(id, cancellationToken);
        if (existing is null)
        {
            return Result.Failure(ErrorType.NotFound, "Role not found.");
        }

        var name = request.Name.Trim();

        if (existing.Role.IsSystem)
        {
            if (!string.Equals(name, existing.Role.Name, StringComparison.Ordinal))
            {
                return Result.Failure(ErrorType.Validation, "A system role cannot be renamed.");
            }

            if (!request.IsActive)
            {
                return Result.Failure(ErrorType.Validation, "A system role cannot be deactivated.");
            }
        }

        if (await _roles.NameExistsAsync(name, id, cancellationToken))
        {
            return Result.Failure(ErrorType.Conflict, "A role with that name already exists.");
        }

        var role = new Role
        {
            Id = id,
            Name = name,
            Description = string.IsNullOrWhiteSpace(request.Description) ? null : request.Description.Trim(),
            IsActive = request.IsActive
        };

        try
        {
            if (!await _roles.UpdateAsync(role, cancellationToken))
            {
                return Result.Failure(ErrorType.NotFound, "Role not found.");
            }
        }
        catch (DuplicateRecordException)
        {
            return Result.Failure(ErrorType.Conflict, "A role with that name already exists.");
        }

        _logger.LogInformation("Role {RoleId} ({Name}) updated", id, role.Name);
        return Result.Success();
    }

    public async Task<Result> DeleteAsync(int id, CancellationToken cancellationToken = default)
    {
        try
        {
            await _roles.DeleteAsync(id, cancellationToken);
        }
        catch (SecurityRuleException ex)
        {
            return Result.Failure(MapRuleError(ex), ex.Message);
        }

        _logger.LogInformation("Role {RoleId} deleted", id);
        return Result.Success();
    }

    public async Task<Result> SetPermissionsAsync(int id, IEnumerable<int> permissionIds, CancellationToken cancellationToken = default)
    {
        try
        {
            await _roles.SetPermissionsAsync(id, permissionIds, cancellationToken);
        }
        catch (SecurityRuleException ex)
        {
            return Result.Failure(MapRuleError(ex), ex.Message);
        }

        _logger.LogInformation("Permissions of role {RoleId} replaced", id);
        return Result.Success();
    }

    // ----- helpers -----

    private static ErrorType MapRuleError(SecurityRuleException ex) => ex.Code switch
    {
        SqlErrors.RoleNotFound => ErrorType.NotFound,
        SqlErrors.SystemRolePermissions => ErrorType.Validation,
        SqlErrors.SystemRoleDelete => ErrorType.Validation,
        SqlErrors.RoleStillAssigned => ErrorType.Conflict,
        _ => ErrorType.Validation
    };

    private static RoleDto ToDto(RoleWithCounts row) => new()
    {
        Id = row.Role.Id,
        Name = row.Role.Name,
        Description = row.Role.Description,
        IsSystem = row.Role.IsSystem,
        IsActive = row.Role.IsActive,
        UserCount = row.UserCount,
        PermissionCount = row.PermissionCount,
        CreatedAtUtc = row.Role.CreatedAtUtc.AsUtc()
    };

    private async Task<RoleDetailDto> ToDetailDtoAsync(RoleWithCounts row, CancellationToken cancellationToken)
    {
        var permissionIds = await _roles.GetPermissionIdsAsync(row.Role.Id, cancellationToken);
        var all = await _permissions.GetAllAsync(cancellationToken);

        var held = new HashSet<int>(permissionIds);
        var permissions = all
            .Where(p => held.Contains(p.Id))
            .Select(p => new PermissionDto
            {
                Id = p.Id,
                Code = p.Code,
                Name = p.Name,
                Module = p.Module,
                Description = p.Description,
                SortOrder = p.SortOrder,
                Roles = [row.Role.Name]
            })
            .ToArray();

        return new RoleDetailDto
        {
            Id = row.Role.Id,
            Name = row.Role.Name,
            Description = row.Role.Description,
            IsSystem = row.Role.IsSystem,
            IsActive = row.Role.IsActive,
            UserCount = row.UserCount,
            PermissionCount = row.PermissionCount,
            CreatedAtUtc = row.Role.CreatedAtUtc.AsUtc(),
            PermissionIds = permissionIds.ToArray(),
            Permissions = permissions
        };
    }
}
