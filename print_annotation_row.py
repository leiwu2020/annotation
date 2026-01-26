from app import app, db, AnnotationRow
import json

with app.app_context():
    rows = AnnotationRow.query.all()
    for r in rows:
        print({
            'id': r.id,
            'assignment_id': r.assignment_id,
            'row_index': r.row_index,
            'data': json.loads(r.data),
            'updated_at': r.updated_at.isoformat() if r.updated_at else None
        })
