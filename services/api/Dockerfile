FROM node:20-alpine
RUN corepack enable
WORKDIR /app
COPY package.json ./
RUN pnpm install --prod=false || true
COPY . .
RUN pnpm prisma generate && pnpm build || true
EXPOSE 3000
CMD ["node", "dist/server.js"]
