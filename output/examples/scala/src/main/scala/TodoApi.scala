import cats.effect.*
import com.comcast.ip4s.*
import io.circe.*
import io.circe.generic.semiauto.*
import io.circe.syntax.*
import org.http4s.*
import org.http4s.circe.*
import org.http4s.circe.CirceEntityCodec.{circeEntityDecoder, circeEntityEncoder}
import org.http4s.dsl.Http4sDsl
import org.http4s.ember.server.EmberServerBuilder

case class Todo(id: Long, title: String, done: Boolean, createdAt: Long)

object Todo:
  given Encoder[Todo] = deriveEncoder[Todo]
  given Decoder[Todo] = deriveDecoder[Todo]

case class CreateTodoRequest(title: String)

object CreateTodoRequest:
  given Decoder[CreateTodoRequest] = deriveDecoder[CreateTodoRequest]

case class UpdateTodoRequest(title: Option[String], done: Option[Boolean])

object UpdateTodoRequest:
  given Decoder[UpdateTodoRequest] = deriveDecoder[UpdateTodoRequest]

object TodoApi extends IOApp:

  private val port: Port =
    sys.env.get("PORT").flatMap(p => scala.util.Try(p.toInt).toOption)
      .flatMap(Port.fromInt)
      .getOrElse(port"3000")

  override def run(args: List[String]): IO[ExitCode] =
    for
      todos  <- Ref[IO].of(Vector.empty[Todo])
      nextId <- Ref[IO].of(1L)
      service = makeService(todos, nextId)
      _ <- EmberServerBuilder
        .default[IO]
        .withHost(ipv4"0.0.0.0")
        .withPort(port)
        .withHttpApp(service)
        .build
        .use(_ => IO.never)
    yield ExitCode.Success

  private def makeService(
      todos: Ref[IO, Vector[Todo]],
      nextId: Ref[IO, Long]
  ): HttpApp[IO] =
    val dsl = Http4sDsl[IO]
    import dsl.*

    def notFound(id: Long): IO[Response[IO]] =
      NotFound(Json.obj("error" -> s"todo $id not found".asJson))

    def badRequest(message: String): IO[Response[IO]] =
      BadRequest(Json.obj("error" -> message.asJson))

    def parseId(id: String): Option[Long] =
      scala.util.Try(id.toLong).toOption

    HttpRoutes
      .of[IO] {
        case GET -> Root / "todos" =>
          todos.get.flatMap(t => Ok(t.asJson))

        case req @ POST -> Root / "todos" =>
          req.as[CreateTodoRequest].flatMap { r =>
            val title = r.title.trim
            if title.isEmpty then badRequest("title must not be empty")
            else
              nextId.modify(i => (i + 1, i)).flatMap { id =>
                val todo = Todo(id, title, done = false, createdAt = now())
                todos.update(_ :+ todo).flatMap(_ => Created(todo.asJson))
              }
          }

        case GET -> Root / "todos" / id =>
          parseId(id) match {
            case None => badRequest(s"invalid id: $id")
            case Some(i) =>
              todos.get.flatMap { list =>
                list.find(_.id == i) match {
                  case Some(t) => Ok(t.asJson)
                  case None    => notFound(i)
                }
              }
          }

        case req @ PATCH -> Root / "todos" / id =>
          parseId(id) match {
            case None => badRequest(s"invalid id: $id")
            case Some(i) =>
              req.as[UpdateTodoRequest].flatMap { u =>
                u.title.map(_.trim).filter(_.isEmpty) match {
                  case Some(_) => badRequest("title must not be empty")
                  case None    =>
                    todos.modify { list =>
                      list.find(_.id == i) match {
                        case None => (list, None)
                        case Some(t) =>
                          val updated = t.copy(
                            title = u.title.map(_.trim).getOrElse(t.title),
                            done = u.done.getOrElse(t.done)
                          )
                          (list.map(x => if x.id == t.id then updated else x), Some(updated))
                      }
                    }.flatMap {
                      case None    => notFound(i)
                      case Some(t) => Ok(t.asJson)
                    }
                }
              }
          }

        case DELETE -> Root / "todos" / id =>
          parseId(id) match {
            case None => badRequest(s"invalid id: $id")
            case Some(i) =>
              todos.modify { list =>
                list.find(_.id == i) match {
                  case None    => (list, false)
                  case Some(t) => (list.filterNot(_.id == t.id), true)
                }
              }.flatMap {
                case true  => NoContent()
                case false => notFound(i)
              }
          }
      }
      .orNotFound

  private def now(): Long =
    java.time.Instant.now().getEpochSecond
