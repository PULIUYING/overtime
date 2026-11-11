FROM nginx:stable-alpine
COPY index.html style.css app.js config.js holidays.js accounts.js photos.js companies.js payroll.js payroll-core.js /usr/share/nginx/html/
EXPOSE 80
