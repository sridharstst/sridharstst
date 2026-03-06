FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS base

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
        curl \
        ca-certificates \
        icu-libs && \
    rm -rf /var/cache/apk/*


RUN addgroup -g 1001 -S appuser && \
    adduser -S -D -H -u 1001 -s /sbin/nologin -G appuser appuser

WORKDIR /app
EXPOSE 80
EXPOSE 443

FROM mcr.microsoft.com/dotnet/sdk:8.0-alpine AS build

RUN apk update && \
    apk upgrade && \
    rm -rf /var/cache/apk/*

WORKDIR /src
COPY ["WEB.LABV1/BloodBank/BloodBank/BloodBankManagement/BloodBankManagement.csproj", "WEB.LABV1/BloodBank/BloodBank/BloodBankManagement/"]
COPY ["WEB.LABV1/BloodBank/BloodBank/BloodBankManagement.Contracts/BloodBankManagement.Contracts.csproj", "WEB.LABV1/BloodBank/BloodBank/BloodBankManagement.Contracts/"]
COPY ["WEB.LABV1/BloodBank/BloodBank/MasterManagement/MasterManagement.csproj", "WEB.LABV1/BloodBank/BloodBank/MasterManagement/"]
COPY ["WEB.LABV1/DEV.Common/DEV.Common.csproj", "WEB.LABV1/DEV.Common/"]
COPY ["WEB.LABV1/BloodBank/BloodBank/Shared/Shared.csproj", "WEB.LABV1/BloodBank/BloodBank/Shared/"]

WORKDIR /src/WEB.LABV1/BloodBank/BloodBank/BloodBankManagement
RUN dotnet restore "BloodBankManagement.csproj"
WORKDIR /src
COPY . .
WORKDIR /src/WEB.LABV1/BloodBank/BloodBank/BloodBankManagement
RUN dotnet build "BloodBankManagement.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "BloodBankManagement.csproj" -c Release -o /app/publish /p:UseAppHost=false

FROM base AS final
WORKDIR /app
COPY --from=publish /app/publish .
RUN chown -R appuser:appuser /app
USER appuser
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:80/health || exit 1


ENTRYPOINT ["dotnet", "BloodBankManagement.dll"]