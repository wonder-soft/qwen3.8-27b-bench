ThisBuild / scalaVersion := "3.3.4"
ThisBuild / version := "0.1.0"
ThisBuild / organization := "local"

lazy val root = project
  .in(file("."))
  .settings(
    name := "todo-api",
    libraryDependencies ++= Seq(
      "org.http4s"   %% "http4s-ember-server" % "0.23.27",
      "org.http4s"   %% "http4s-dsl"          % "0.23.27",
      "org.http4s"   %% "http4s-circe"        % "0.23.27",
      "io.circe"     %% "circe-generic"       % "0.14.10",
      "org.typelevel" %% "cats-effect"        % "3.5.7"
    )
  )
