from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from app.config import settings

pool = ConnectionPool(settings.database_url, kwargs={"row_factory": dict_row}, open=False)
