# syntax=docker/dockerfile:1

# Inventory_Shipment.API as a Linux container image.
#
# Built and run by deploy/docker-compose.yml - see deploy/README.md. The web app is a separate image
# built from the Inventory_Shipment_Frontend repository; this one serves only /api and /health.

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

# The project files first, so the NuGet restore stays cached until a package reference changes.
COPY Inventory_Shipment.API/Inventory_Shipment.API.csproj Inventory_Shipment.API/
COPY Inventory_Shipment.Service/Inventory_Shipment.Service.csproj Inventory_Shipment.Service/
COPY Inventory_Shipment.Repository/Inventory_Shipment.Repository.csproj Inventory_Shipment.Repository/
COPY Inventory_Shipment.Model/Inventory_Shipment.Model.csproj Inventory_Shipment.Model/
RUN dotnet restore Inventory_Shipment.API/Inventory_Shipment.API.csproj

COPY Inventory_Shipment.API/ Inventory_Shipment.API/
COPY Inventory_Shipment.Service/ Inventory_Shipment.Service/
COPY Inventory_Shipment.Repository/ Inventory_Shipment.Repository/
COPY Inventory_Shipment.Model/ Inventory_Shipment.Model/
RUN dotnet publish Inventory_Shipment.API/Inventory_Shipment.API.csproj -c Release -o /app --no-restore

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app

# App_Data holds the Data Protection keys that encrypt the SMTP password saved in Settings > Email.
# docker-compose mounts a volume here; creating the folder owned by the non-root "app" user first
# means a new volume starts out writable by it.
RUN mkdir -p /app/App_Data/keys && chown -R "$APP_UID" /app/App_Data

COPY --from=build /app .

USER $APP_UID
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "Inventory_Shipment.API.dll"]
