package demo;

/** 自检工程里唯一的类：内容不重要，"能被编译且可被构建缓存复用"才重要。 */
public final class Hello {
    private Hello() {
    }

    public static String greet(String who) {
        return "hello, " + who + " (from mc-build-hub fixture)";
    }
}
