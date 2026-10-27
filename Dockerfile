FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev || true
COPY . .
ENV PORT=7860
EXPOSE 7860
CMD ["npm", "start"]
