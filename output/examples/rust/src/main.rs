use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tower_http::trace::TraceLayer;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Todo {
    id: u64,
    title: String,
    done: bool,
    created_at: u64,
}

#[derive(Deserialize)]
struct CreateTodoRequest {
    title: String,
}

#[derive(Deserialize)]
struct UpdateTodoRequest {
    title: Option<String>,
    done: Option<bool>,
}

#[derive(Clone)]
struct AppState {
    todos: Arc<Mutex<Vec<Todo>>>,
    next_id: Arc<Mutex<u64>>,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            todos: Arc::new(Mutex::new(Vec::new())),
            next_id: Arc::new(Mutex::new(1)),
        }
    }
}

struct ApiError(StatusCode, String);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = serde_json::json!({ "error": self.1 }).to_string();
        (self.0, body).into_response()
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

async fn list_todos(State(state): State<AppState>) -> Json<Vec<Todo>> {
    Json(state.todos.lock().unwrap().clone())
}

async fn get_todo(
    Path(id): Path<u64>,
    State(state): State<AppState>,
) -> Result<Json<Todo>, ApiError> {
    let todos = state.todos.lock().unwrap();
    todos
        .iter()
        .find(|t| t.id == id)
        .cloned()
        .map(Json)
        .ok_or(ApiError(
            StatusCode::NOT_FOUND,
            format!("todo {id} not found"),
        ))
}

async fn create_todo(
    State(state): State<AppState>,
    Json(req): Json<CreateTodoRequest>,
) -> Result<(StatusCode, Json<Todo>), ApiError> {
    let title = req.title.trim().to_string();
    if title.is_empty() {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "title must not be empty".into(),
        ));
    }
    let id = *state.next_id.lock().unwrap();
    *state.next_id.lock().unwrap() += 1;
    let todo = Todo {
        id,
        title,
        done: false,
        created_at: now(),
    };
    state.todos.lock().unwrap().push(todo.clone());
    Ok((StatusCode::CREATED, Json(todo)))
}

async fn update_todo(
    Path(id): Path<u64>,
    State(state): State<AppState>,
    Json(req): Json<UpdateTodoRequest>,
) -> Result<Json<Todo>, ApiError> {
    let mut todos = state.todos.lock().unwrap();
    let todo = todos
        .iter_mut()
        .find(|t| t.id == id)
        .ok_or(ApiError(
            StatusCode::NOT_FOUND,
            format!("todo {id} not found"),
        ))?;
    if let Some(title) = req.title {
        let title = title.trim().to_string();
        if title.is_empty() {
            return Err(ApiError(
                StatusCode::BAD_REQUEST,
                "title must not be empty".into(),
            ));
        }
        todo.title = title;
    }
    if let Some(done) = req.done {
        todo.done = done;
    }
    Ok(Json(todo.clone()))
}

async fn delete_todo(
    Path(id): Path<u64>,
    State(state): State<AppState>,
) -> Result<StatusCode, ApiError> {
    let mut todos = state.todos.lock().unwrap();
    let before = todos.len();
    todos.retain(|t| t.id != id);
    if todos.len() == before {
        return Err(ApiError(
            StatusCode::NOT_FOUND,
            format!("todo {id} not found"),
        ));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[tokio::main]
async fn main() {
    let state = AppState::default();
    let app = Router::new()
        .route("/todos", get(list_todos).post(create_todo))
        .route(
            "/todos/{id}",
            get(get_todo).patch(update_todo).delete(delete_todo),
        )
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);
    let addr = format!("0.0.0.0:{port}");
    let listener = tokio::net::TcpListener::bind(&addr)
        .await
        .expect("failed to bind");
    println!("todo api listening on http://{addr}");
    axum::serve(listener, app).await.unwrap();
}
