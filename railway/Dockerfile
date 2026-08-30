FROM frappe/erpnext:v16.33.0
USER root
RUN pip install --no-cache-dir supervisor
COPY supervisord.conf /home/frappe/supervisord.conf
COPY start-railway.sh /usr/local/bin/start-railway.sh
RUN chmod 755 /usr/local/bin/start-railway.sh
USER frappe
CMD ["start-railway.sh"]
