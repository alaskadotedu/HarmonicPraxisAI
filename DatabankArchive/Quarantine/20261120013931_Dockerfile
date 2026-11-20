FROM ://microsoft.com
WORKDIR /app
RUN apt-get update && apt-get install -y curl gnupg ca-certificates && mkdir -p /etc/apt/keyrings && curl -fsSL https://nodesource.com | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://nodesource.com nodistro main" > /etc/apt/sources.list.d/nodesource.list && apt-get update && apt-get install -y nodejs && rm -rf /var/lib/apt/lists/*
COPY . /app
EXPOSE 8110
CMD ["pwsh", "-NoLogo", "-ExecutionPolicy", "Bypass", "-File", "/app/Start-HarmonicFrontendStack.ps1"]
