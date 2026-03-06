
FROM mcr.microsoft.com/dotnet/aspnet:8.0-alpine AS base

RUN apk update && \
    apk upgrade && \
    apk add --no-cache \
        curl \
        ca-certificates \
        icu-libs && \
    rm -rf /var/cache/apk/*
ENV DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false

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

COPY ["WEB.LABV1/DEV.API.SERVICE/DEV.API.SERVICE.csproj", "WEB.LABV1/DEV.API.SERVICE/"]
COPY ["WEB.LABV1/DEV.Common/DEV.Common.csproj", "WEB.LABV1/DEV.Common/"]
COPY ["WEB.LABV1/Dev.IRepository/Dev.IRepository.csproj", "WEB.LABV1/Dev.IRepository/"]
COPY ["WEB.LABV1/DEV.Model/DEV.Model.csproj", "WEB.LABV1/DEV.Model/"]
COPY ["WEB.LABV1/Dev.Repository/Dev.Repository.csproj", "WEB.LABV1/Dev.Repository/"]
COPY ["WEB.LABV1/WEB.Model.EF/DEV.Model.EF.csproj", "WEB.LABV1/WEB.Model.EF/"]
COPY ["WEB.LABV1/BloodBank/BloodBank/Shared/Shared.csproj", "WEB.LABV1/BloodBank/BloodBank/Shared/"]



WORKDIR /src/WEB.LABV1/DEV.API.SERVICE
RUN dotnet restore "DEV.API.SERVICE.csproj"

WORKDIR /src
COPY . .

WORKDIR /src/WEB.LABV1/DEV.API.SERVICE
RUN dotnet build "DEV.API.SERVICE.csproj" -c Release -o /app/build

FROM build AS publish
RUN dotnet publish "DEV.API.SERVICE.csproj" -c Release -o /app/publish \
    /p:UseAppHost=false


#RUN dotnet publish "DEV.API.SERVICE.csproj" -c Release -o /app/publish \
    #--self-contained true \
    #--runtime linux-musl-x64 \
    #/p:PublishTrimmed=true \
    #/p:TrimMode=link \
    #/p:PublishReadyToRun=false


FROM base AS final
WORKDIR /app

COPY --from=publish /app/publish .

RUN chown -R appuser:appuser /app

USER appuser

HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:80/health || exit 1

ENTRYPOINT ["dotnet", "DEV.API.SERVICE.dll"]